// Copyright 2026 DoorDash, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

//  Swappable coverage strategies that determine when a fuzz input is "interesting."
//

/// Determines how the fuzzer decides if an input is interesting (i.e., worth adding to the corpus).
///
/// Different strategies trade off between precision and performance:
/// - `.signatureMatch`: Exact edge-set matching via inverted index. Zero false positives. Default.
/// - `.newEdge`: Bitmap merge — any previously-unseen edge is interesting. Matches AFL/libFuzzer.
/// - `.pathTrie`: Trie-based path tracking. O(1) per edge hit and O(1) uniqueness check.
/// - `.alwaysInteresting`: Every input is added. Useful for testing without coverage.
public enum CoverageStrategyKind: Sendable {
    /// Signature match strategy (default).
    ///
    /// Tracks all previously-seen edge sets and uses an inverted index to check
    /// if the current run's edge set exactly matches any of them. An input is
    /// interesting if its exact set of covered edges hasn't been seen before.
    ///
    /// No hashing — no false positives. The reject path is O(covered_edges * avg_signatures_per_edge).
    /// With typical coverage (4-8 edges, ~100 unique signatures), this is ~8-16 integer increments.
    case signatureMatch

    /// New edge strategy (bitmap merge).
    ///
    /// Uses `mergeCoverageIntoBitmap` to check if any previously-unseen edge
    /// was hit. Aligns with the AFL/libFuzzer model where any new edge is interesting.
    case newEdge

    /// Path trie strategy.
    ///
    /// Tracks every unique execution path (ordered edge sequence) in a trie.
    /// O(1) per edge hit (advance trie pointer), O(1) uniqueness check at end of run.
    /// Installs the `trieEdgeHook` automatically — no need to set `edgeHook` separately.
    /// Order-sensitive: A→B→C is different from A→C→B.
    case pathTrie

    /// Always interesting (for testing).
    ///
    /// Every input is added to the corpus unconditionally. Useful for tests
    /// that need deterministic corpus growth without depending on coverage data.
    case alwaysInteresting

    /// Whether coverage changed between the expected and actual sparse coverage.
    ///
    /// Used by regression to decide if the corpus needs to be re-fuzzed.
    /// Order-sensitive strategies (pathTrie) compare arrays directly.
    /// Set-based strategies (signatureMatch, newEdge) compare sorted indices.
    func coverageChanged(expected: SparseCoverage, actual: SparseCoverage) -> Bool {
        switch self {
        case .pathTrie:
            return expected != actual
        case .signatureMatch, .newEdge:
            return expected.indices.sorted() != actual.indices.sorted()
        case .alwaysInteresting:
            return false
        }
    }
}

/// A closure that decides if an input is interesting and adds it to the corpus.
///
/// Returns `true` if the input was interesting and added.
typealias CoverageStrategyFn<each Input: Codable & Sendable> = (
    _ input: (repeat each Input),
    _ scheduleBytes: [UInt8]?,
    _ context: SanCovCounters.MeasurementContext,
    _ coverageClient: CoverageCountersClient,
    _ corpus: Corpus<repeat each Input>
) -> Bool

/// Called once with the measurement context before the first test execution.
/// Strategies that need to attach to the context (e.g., pathTrie) use this
/// to set up before any edges are recorded.
typealias CoverageStrategySetup = (
    _ context: SanCovCounters.MeasurementContext
) -> Void

/// A coverage strategy with an optional setup phase.
struct CoverageStrategy<each Input: Codable & Sendable> {
    let setup: CoverageStrategySetup?
    let evaluate: CoverageStrategyFn<repeat each Input>
}

/// Creates a coverage strategy for the given kind.
///
/// The returned strategy encapsulates all interestingness logic and corpus addition.
/// It captures any mutable state it needs (e.g., the inverted index).
func makeCoverageStrategy<each Input: Codable & Sendable>(
    _ kind: CoverageStrategyKind
) -> CoverageStrategy<repeat each Input> {
    switch kind {
    case .signatureMatch:
        return CoverageStrategy(setup: nil, evaluate: makeSignatureMatchStrategy())
    case .newEdge:
        return CoverageStrategy(setup: nil, evaluate: makeNewEdgeStrategy())
    case .pathTrie:
        return makePathTrieStrategy()
    case .alwaysInteresting:
        return CoverageStrategy(setup: nil, evaluate: makeAlwaysInterestingStrategy())
    }
}

// MARK: - Signature Match Strategy

/// Inverted index for exact edge-set duplicate detection.
///
/// Stores all previously-seen coverage signatures (edge sets) and provides
/// O(covered_edges) duplicate checking via an inverted index from edges to
/// signature IDs.
///
/// For each stored signature, tracks:
/// - Its total edge count
/// - A per-iteration hit counter (how many of its edges were seen this run)
///
/// The inverted index maps each edge index to the list of signature IDs that
/// contain it. When an edge is observed, its signatures' hit counters are
/// incremented. After all edges are observed, a signature is a match iff
/// `hits == signature_size AND covered_count == signature_size`.
private struct SignatureIndex {
    /// Number of edges in each stored signature.
    private var signatureSizes: [Int] = []

    /// Hit counters per signature, reset each iteration.
    private var signatureHits: [Int] = []

    /// Inverted index: edge index → list of signature IDs containing that edge.
    private var edgeToSignatures: [UInt32: [Int]] = [:]

    /// Number of stored signatures.
    var count: Int { signatureSizes.count }

    /// Reset all hit counters for a new iteration.
    mutating func resetHits() {
        for i in signatureHits.indices {
            signatureHits[i] = 0
        }
    }

    /// Check if the given covered edges exactly match any stored signature.
    ///
    /// - Parameter coveredIndices: Buffer of edge indices hit this run.
    /// - Returns: `true` if a matching signature exists (duplicate), `false` if novel.
    mutating func isDuplicate(coveredIndices: UnsafeBufferPointer<UInt32>) -> Bool {
        let coveredCount = coveredIndices.count
        if coveredCount == 0 { return false }

        // Reset hits from previous check
        resetHits()

        // Increment hit counters for each covered edge
        for i in 0..<coveredCount {
            let edge = coveredIndices[i]
            if let sigIDs = edgeToSignatures[edge] {
                for sigID in sigIDs {
                    signatureHits[sigID] += 1
                }
            }
        }

        // Check if any signature is fully matched
        for i in 0..<signatureSizes.count {
            if signatureHits[i] == signatureSizes[i] && coveredCount == signatureSizes[i] {
                return true
            }
        }
        return false
    }

    /// Register a new signature (edge set) in the index.
    ///
    /// - Parameter indices: The edge indices of the new signature.
    mutating func addSignature(_ indices: [UInt32]) {
        let sigID = signatureSizes.count
        signatureSizes.append(indices.count)
        signatureHits.append(0)

        for edge in indices {
            edgeToSignatures[edge, default: []].append(sigID)
        }
    }
}

/// Signature match strategy: exact edge-set matching via inverted index.
///
/// Zero false positives — if the edge set hasn't been seen before, it's interesting.
private func makeSignatureMatchStrategy<each Input: Codable & Sendable>(
) -> CoverageStrategyFn<repeat each Input> {
    var index = SignatureIndex()

    return { input, scheduleBytes, context, coverageClient, corpus in
        // Zero-copy access to covered indices buffer
        let isDuplicate = coverageClient.withCoveredIndices(context) { buffer in
            index.isDuplicate(coveredIndices: buffer)
        }

        guard !isDuplicate else {
            return false
        }

        // Novel edge set — snapshot coverage and add to corpus
        guard let sparse = try? coverageClient.snapshotCoveredArraysWithContext(context) else {
            return false
        }

        // Register in the inverted index
        index.addSignature(Array(sparse.indices))

        corpus.mergeCoverageAndAdd(input: input, scheduleBytes: scheduleBytes, sparse: sparse)
        return true
    }
}

// MARK: - New Edge Strategy

/// New edge strategy: uses bitmap merge to detect any previously-unseen edge.
///
/// Aligns with AFL/libFuzzer model.
private func makeNewEdgeStrategy<each Input: Codable & Sendable>(
) -> CoverageStrategyFn<repeat each Input> {
    return { input, scheduleBytes, context, coverageClient, corpus in
        // Merge coverage directly into corpus bitmap - returns true if any new edge found
        let foundNewEdge = coverageClient.mergeCoverageIntoBitmap(
            context,
            corpus.bitmapStorage,
            corpus.bitmapWordCount,
            true // mergeAll: merge all edges, not just new ones
        )

        guard foundNewEdge else {
            return false
        }

        // New edge found - snapshot for the corpus entry
        guard let sparse = try? coverageClient.snapshotCoveredArraysWithContext(context) else {
            return false
        }

        corpus.addEntry(input: input, scheduleBytes: scheduleBytes, sparse: sparse)
        return true
    }
}

// MARK: - Path Trie Strategy

/// Path trie strategy: O(1) per-hit path tracking, O(1) uniqueness check.
///
/// Creates a PathTrie, installs the trie edge hook, and checks uniqueness
/// via `trie.isUniquePath` after each run. The trie is attached to the
/// measurement context so each parallel engine gets its own trie.
private func makePathTrieStrategy<each Input: Codable & Sendable>(
) -> CoverageStrategy<repeat each Input> {
    let trie = PathTrie()

    let setup: CoverageStrategySetup = { context in
        SanCovCounters.attachTrie(trie, to: context)
    }

    var iterationCount = 0

    let evaluate: CoverageStrategyFn<repeat each Input> = { input, scheduleBytes, context, coverageClient, corpus in
        iterationCount += 1
        let iter = iterationCount
        let isNovel = trie.isUniquePath

        if iter <= 10 || iter % 500 == 0 {
            trie.dump()
            print("[pathTrie iter=\(iter)] novel=\(isNovel) corpus=\(corpus.entries.count)")
        }

        defer {
            trie.reset()
        }

        guard isNovel else {
            return false
        }

        trie.markTerminal()

        if let sparse = try? coverageClient.snapshotCoveredArraysWithContext(context) {
            corpus.mergeCoverageAndAdd(input: input, scheduleBytes: scheduleBytes, sparse: sparse)
        } else {
            corpus.addEntry(input: input, scheduleBytes: scheduleBytes, sparse: SparseCoverage())
        }
        return true
    }

    return CoverageStrategy(setup: setup, evaluate: evaluate)
}

// MARK: - Always Interesting Strategy

/// Always interesting strategy: every input is added unconditionally.
private func makeAlwaysInterestingStrategy<each Input: Codable & Sendable>(
) -> CoverageStrategyFn<repeat each Input> {
    return { input, scheduleBytes, context, coverageClient, corpus in
        if let sparse = try? coverageClient.snapshotCoveredArraysWithContext(context) {
            corpus.mergeCoverageAndAdd(input: input, scheduleBytes: scheduleBytes, sparse: sparse)
        } else {
            corpus.addEntry(input: input, scheduleBytes: scheduleBytes, sparse: SparseCoverage())
        }
        return true
    }
}
