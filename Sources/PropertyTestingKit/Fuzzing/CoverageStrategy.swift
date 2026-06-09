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

/// Determines how the fuzzer decides if an input is "interesting" (worth adding to the corpus).
///
/// PropertyTestingKit ships four built-in strategies as static factories:
/// - `.signatureMatch`: Exact edge-set matching via inverted index. Zero false positives.
/// - `.newEdge`: Bitmap merge — any previously-unseen edge is interesting. Matches AFL/libFuzzer.
/// - `.pathTrie` (default): Trie-based ordered-path tracking. O(1) per edge hit and uniqueness check.
/// - `.alwaysInteresting`: Every input is added. Useful for testing without coverage.
///
/// You can also build a custom strategy from a high-level decision over the run's coverage
/// (`SparseCoverage`) and the `Corpus`:
/// ```swift
/// fuzz(coverageStrategy: CoverageStrategy { sparse, corpus, input, schedule in
///     guard isNovel(sparse) else { return false }
///     corpus.addEntry(input: input, scheduleBytes: schedule, sparse: sparse)
///     return true
/// }) { ... }
/// ```
/// Identifies a built-in coverage strategy so it can be rebuilt at a *different* input pack —
/// schedule fuzzing runs over `([UInt8], repeat each Input)`, a different pack than the user's
/// `(repeat each Input)`, and a strategy value can't cross pack instantiations. Top-level (not
/// nested in the generic `CoverageStrategy`) so the tag itself is pack-agnostic.
/// `nil` for custom strategies (which can't be re-packed; see `CoverageStrategy.builtin(_:)`).
enum CoverageStrategyBuiltin: Sendable, Equatable {
    case signatureMatch, newEdge, pathTrie, alwaysInteresting
}

public struct CoverageStrategy<each Input: Codable & Sendable>: Sendable {
    /// The built-in kind, or `nil` for a custom strategy.
    let builtin: CoverageStrategyBuiltin?

    /// Builds a fresh evaluator (with fresh per-engine state, e.g. a new trie/index).
    /// Called once per parallel engine so engines never share mutable coverage state.
    let makeEvaluator: @Sendable () -> CoverageEvaluator<repeat each Input>

    /// Internal designated initializer used by the built-in factories.
    init(
        builtin: CoverageStrategyBuiltin?,
        makeEvaluator: @escaping @Sendable () -> CoverageEvaluator<repeat each Input>
    ) {
        self.builtin = builtin
        self.makeEvaluator = makeEvaluator
    }

    /// Build a custom strategy from a high-level decision over public coverage data.
    ///
    /// `decide` is called once per fuzz iteration with the edges the run covered
    /// (`sparse`), the shared `corpus`, the `input`, and its optional schedule bytes.
    /// Return `true` if the input was interesting; add it to the corpus yourself via
    /// `corpus.addEntry(...)` / `corpus.mergeCoverageAndAdd(...)`.
    ///
    /// - Parameter onEdge: The strategy's per-edge function — the *measurement*
    ///   half (what each edge hit does), paired with `decide`'s *judgement* half.
    ///   Called once per edge per iteration, on the edge's first hit, for edges
    ///   that route to the engine's measurement context. The context co-owns the
    ///   closure's state, so capture freely (the `.pathTrie` strategy captures
    ///   its trie this way). `nil` (the default) leaves the plain map recording.
    /// - Note: `decide` is shared across parallel engines. Keep it free of mutable state,
    ///   or use `init(onEdge:makeDecision:)` to get a fresh decision per engine.
    public init(
        onEdge: (@Sendable (UInt32) -> Void)? = nil,
        _ decide: @escaping CoverageDecision<repeat each Input>
    ) {
        self.init(onEdge: onEdge, makeDecision: { decide })
    }

    /// Build a custom strategy whose decision holds fresh per-engine state.
    ///
    /// `makeDecision` is called once per parallel engine to produce an isolated decision
    /// closure, mirroring how the built-ins allocate a fresh trie/index per engine.
    ///
    /// - Parameter onEdge: The strategy's per-edge function, attached to each
    ///   engine's measurement context during setup (see `init(onEdge:_:)`).
    public init(
        onEdge: (@Sendable (UInt32) -> Void)? = nil,
        makeDecision: @escaping @Sendable () -> CoverageDecision<repeat each Input>
    ) {
        self.builtin = nil
        self.makeEvaluator = {
            let decide = makeDecision()
            // Attach the per-edge function as an observer in setup, like
            // .pathTrie attaches its trie observer. No onEdge → nothing to
            // attach: a cleared recorder field already means "default".
            let setup: CoverageStrategySetup? = onEdge.map { onEdge in
                { context in
                    SanCovCounters.attachObserver(EdgeObserver(onEdge: onEdge), to: context)
                }
            }
            return CoverageEvaluator(setup: setup, evaluate: { input, scheduleBytes, context, coverageClient, corpus in
                let sparse = (try? coverageClient.snapshotCoveredArraysWithContext(context)) ?? SparseCoverage()
                return decide(sparse, corpus, input, scheduleBytes)
            })
        }
    }
}

// MARK: - Built-in Strategies

extension CoverageStrategy {
    /// Signature match strategy: exact edge-set matching via inverted index. Zero false positives.
    public static var signatureMatch: CoverageStrategy<repeat each Input> {
        CoverageStrategy(builtin: .signatureMatch, makeEvaluator: { CoverageEvaluator(setup: nil, evaluate: makeSignatureMatchStrategy()) })
    }

    /// New edge strategy: bitmap merge — any previously-unseen edge is interesting (AFL/libFuzzer).
    public static var newEdge: CoverageStrategy<repeat each Input> {
        CoverageStrategy(builtin: .newEdge, makeEvaluator: { CoverageEvaluator(setup: nil, evaluate: makeNewEdgeStrategy()) })
    }

    /// Path trie strategy: ordered-path tracking (A→B→C differs from A→C→B). The default.
    public static var pathTrie: CoverageStrategy<repeat each Input> {
        CoverageStrategy(builtin: .pathTrie, makeEvaluator: { makePathTrieStrategy() })
    }

    /// Always-interesting strategy: every input is added. Useful for deterministic tests.
    public static var alwaysInteresting: CoverageStrategy<repeat each Input> {
        CoverageStrategy(builtin: .alwaysInteresting, makeEvaluator: { CoverageEvaluator(setup: nil, evaluate: makeAlwaysInterestingStrategy()) })
    }

    /// Re-create a built-in strategy at *this* input pack. Used by schedule fuzzing, which
    /// runs over the extended pack `([UInt8], repeat each Input)`. A custom strategy
    /// (`builtin == nil`) can't be re-packed, so it falls back to `.pathTrie` — schedule
    /// fuzzing is order-sensitive and `.pathTrie` is its natural strategy anyway.
    static func builtin(_ kind: CoverageStrategyBuiltin?) -> CoverageStrategy<repeat each Input> {
        switch kind {
        case .signatureMatch: return .signatureMatch
        case .newEdge: return .newEdge
        case .alwaysInteresting: return .alwaysInteresting
        case .pathTrie, .none: return .pathTrie
        }
    }
}

/// A custom interestingness decision over public coverage data.
///
/// - Parameters:
///   - sparse: The edges this run covered.
///   - corpus: The corpus to add to when the input is interesting.
///   - input: The input that was just executed.
///   - scheduleBytes: The schedule bytes for the run, if any.
/// - Returns: `true` if the input was interesting and added to the corpus.
public typealias CoverageDecision<each Input: Codable & Sendable> = @Sendable (
    _ sparse: SparseCoverage,
    _ corpus: Corpus<repeat each Input>,
    _ input: (repeat each Input),
    _ scheduleBytes: [UInt8]?
) -> Bool

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

/// A coverage evaluator with an optional setup phase. Built per-engine by `CoverageStrategy`.
struct CoverageEvaluator<each Input: Codable & Sendable> {
    let setup: CoverageStrategySetup?
    let evaluate: CoverageStrategyFn<repeat each Input>
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
/// The strategy contains its trie as Swift state: per-edge work is a Swift
/// function capturing the trie (advance on each first hit, cursor back to root
/// on coverage reset), attached as an edge observer that the measurement
/// context co-owns. Uniqueness is checked via `trie.isUniquePath` after each
/// run. The evaluator (and so the trie) is built per engine, so parallel
/// engines never share a trie cursor.
private func makePathTrieStrategy<each Input: Codable & Sendable>(
) -> CoverageEvaluator<repeat each Input> {
    let trie = PathTrie()

    // Attach the trie observer in setup so iteration 1's edges advance the
    // trie. Attaching lazily on the first evaluate call misses those edges —
    // they've already fired by the time evaluate runs.
    let setup: CoverageStrategySetup = { context in
        SanCovCounters.attachTrie(trie, to: context)
    }

    let evaluate: CoverageStrategyFn<repeat each Input> = { input, scheduleBytes, context, coverageClient, corpus in
        defer {
            trie.reset()
        }

        guard trie.isUniquePath else {
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

    return CoverageEvaluator(setup: setup, evaluate: evaluate)
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
