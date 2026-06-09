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
    /// Always derived from a `CoverageEngine` — every strategy, built-in or
    /// custom, goes through the same public `makeEngine` surface.
    let makeEvaluator: @Sendable () -> CoverageEvaluator<repeat each Input>

    /// Build a custom strategy from a high-level decision over public coverage data.
    ///
    /// `decide` is called once per fuzz iteration with the edges the run covered
    /// (`sparse`), the shared `corpus`, the `input`, and its optional schedule bytes.
    /// Return `true` if the input was interesting; add it to the corpus yourself via
    /// `corpus.addEntry(...)` / `corpus.mergeCoverageAndAdd(...)`.
    ///
    /// - Parameter onEdge: The strategy's per-edge function — the *measurement*
    ///   half (what each edge hit does), paired with `decide`'s *judgement* half.
    ///   Called on EVERY hit of edges that route to the engine's measurement
    ///   context, loop re-executions included — gating (loop immunity, dedup,
    ///   hit-count bucketing) is your strategy's decision, the way `.pathTrie`
    ///   gates itself to first hits. The context co-owns the closure's state,
    ///   so capture freely. `nil` (the default) leaves the plain map recording.
    /// - Note: `onEdge` and `decide` are shared across parallel engines. Keep
    ///   them free of mutable state, or use `init(makeEngine:)` to give each
    ///   engine its own.
    public init(
        onEdge: (@Sendable (UInt32) -> Void)? = nil,
        _ decide: @escaping CoverageDecision<repeat each Input>
    ) {
        self.init(builtin: nil, makeEngine: { CoverageEngine(onEdge: onEdge, decide) })
    }

    /// Build a custom strategy whose per-edge hooks and decision hold fresh
    /// per-engine state.
    ///
    /// `makeEngine` is called once per parallel engine, so the state its
    /// closures capture is engine-isolated by construction — exactly how the
    /// built-in `.pathTrie` allocates a fresh trie per engine. This is the form
    /// to use for any stateful strategy that should be correct under
    /// `parallelism > 1`:
    /// ```swift
    /// CoverageStrategy<Int>(makeEngine: {
    ///     let trie = PathTrie()                       // this engine's state
    ///     return CoverageEngine(
    ///         onEdge: { edge in trie.advance(edge) }, // measurement half
    ///         onReset: { trie.reset() }
    ///     ) { sparse, corpus, input, schedule in      // judgement half
    ///         defer { trie.reset() }
    ///         guard trie.isUniquePath else { return false }
    ///         trie.markTerminal()
    ///         corpus.mergeCoverageAndAdd(input: input, scheduleBytes: schedule, sparse: sparse)
    ///         return true
    ///     }
    /// })
    /// ```
    public init(makeEngine: @escaping @Sendable () -> CoverageEngine<repeat each Input>) {
        self.init(builtin: nil, makeEngine: makeEngine)
    }

    /// Internal designated form of `init(makeEngine:)` that keeps the built-in
    /// tag for schedule-fuzzing re-packing. Converts each engine bundle into a
    /// CoverageEvaluator: hooks become an attached EdgeObserver; the decision
    /// runs over the iteration's sparse snapshot.
    init(
        builtin: CoverageStrategyBuiltin?,
        makeEngine: @escaping @Sendable () -> CoverageEngine<repeat each Input>
    ) {
        self.builtin = builtin
        self.makeEvaluator = {
            let engine = makeEngine()
            // No hooks → nothing to attach: a cleared recorder field already
            // means "default recording".
            let setup: CoverageStrategySetup? = (engine.onEdge != nil || engine.onReset != nil)
                ? { context in
                    SanCovCounters.attachObserver(
                        EdgeObserver(onEdge: engine.onEdge ?? { _ in }, onReset: engine.onReset),
                        to: context
                    )
                }
                : nil
            return CoverageEvaluator(setup: setup, evaluate: { input, scheduleBytes, context, coverageClient, corpus in
                // No coverage, no judgement: a decision over coverage cannot
                // run when the snapshot is unavailable, so the input is not
                // interesting. (Synthesizing empty coverage instead would make
                // a broken measurement look like a novel empty edge set.)
                guard let sparse = try? coverageClient.snapshotCoveredArraysWithContext(context) else {
                    return nil
                }
                return engine.decide(sparse, corpus, input, scheduleBytes) ? sparse : nil
            })
        }
    }
}

/// A strategy's per-engine bundle: the measurement hooks and the decision,
/// sharing one parallel engine's state. Built fresh by `makeEngine` for each
/// engine, so state captured by these closures never crosses engines.
public struct CoverageEngine<each Input: Codable & Sendable>: Sendable {
    /// Called on every hit of edges routing to this engine's measurement
    /// context (see `CoverageStrategy.init(onEdge:_:)` for semantics).
    let onEdge: (@Sendable (UInt32) -> Void)?

    /// Called when the engine's coverage resets between iterations, so
    /// per-iteration state starts each run clean.
    let onReset: (@Sendable () -> Void)?

    /// The judgement half: decides per iteration whether the input was
    /// interesting and adds it to the corpus.
    let decide: CoverageDecision<repeat each Input>

    public init(
        onEdge: (@Sendable (UInt32) -> Void)? = nil,
        onReset: (@Sendable () -> Void)? = nil,
        _ decide: @escaping CoverageDecision<repeat each Input>
    ) {
        self.onEdge = onEdge
        self.onReset = onReset
        self.decide = decide
    }
}

// MARK: - Built-in Strategies

extension CoverageStrategy {
    /// Signature match strategy: exact edge-set matching via inverted index. Zero false positives.
    public static var signatureMatch: CoverageStrategy<repeat each Input> {
        CoverageStrategy(builtin: .signatureMatch, makeEngine: { makeSignatureMatchEngine() })
    }

    /// New edge strategy: bitmap merge — any previously-unseen edge is interesting (AFL/libFuzzer).
    public static var newEdge: CoverageStrategy<repeat each Input> {
        CoverageStrategy(builtin: .newEdge, makeEngine: { makeNewEdgeEngine() })
    }

    /// Path trie strategy: ordered-path tracking (A→B→C differs from A→C→B). The default.
    public static var pathTrie: CoverageStrategy<repeat each Input> {
        CoverageStrategy(builtin: .pathTrie, makeEngine: { makePathTrieEngine() })
    }

    /// Always-interesting strategy: every input is added. Useful for deterministic tests.
    public static var alwaysInteresting: CoverageStrategy<repeat each Input> {
        CoverageStrategy(builtin: .alwaysInteresting, makeEngine: { makeAlwaysInterestingEngine() })
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
/// Returns the run's sparse coverage when the input was interesting (the
/// snapshot already taken for the decision — callers must not re-snapshot),
/// or `nil` when it wasn't.
typealias CoverageStrategyFn<each Input: Codable & Sendable> = (
    _ input: (repeat each Input),
    _ scheduleBytes: [UInt8]?,
    _ context: SanCovCounters.MeasurementContext,
    _ coverageClient: CoverageCountersClient,
    _ corpus: Corpus<repeat each Input>
) -> SparseCoverage?

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
/// Zero false positives — if the edge set hasn't been seen before, it's
/// interesting. The inverted index is this engine's state, wrapped in a
/// `SyncBox` because the decision closure is `@Sendable`.
private func makeSignatureMatchEngine<each Input: Codable & Sendable>(
) -> CoverageEngine<repeat each Input> {
    let index = SyncBox(SignatureIndex())

    return CoverageEngine { sparse, corpus, input, scheduleBytes in
        let isDuplicate = index.update { idx in
            sparse.indices.withUnsafeBufferPointer { idx.isDuplicate(coveredIndices: $0) }
        }

        guard !isDuplicate else {
            return false
        }

        // Novel edge set — register it and add to the corpus.
        index.update { $0.addSignature(sparse.indices) }
        corpus.mergeCoverageAndAdd(input: input, scheduleBytes: scheduleBytes, sparse: sparse)
        return true
    }
}

// MARK: - New Edge Strategy

/// New edge strategy: any previously-unseen edge (per the corpus's global
/// seen-edges bitmap) is interesting. Aligns with AFL/libFuzzer model.
private func makeNewEdgeEngine<each Input: Codable & Sendable>(
) -> CoverageEngine<repeat each Input> {
    CoverageEngine { sparse, corpus, input, scheduleBytes in
        guard corpus.mergeCoverage(sparse) else {
            return false
        }

        // mergeCoverage already merged the bitmap — record without re-merging.
        corpus.addEntry(input: input, scheduleBytes: scheduleBytes, sparse: sparse)
        return true
    }
}

// MARK: - Path Trie Strategy

/// Path trie strategy: O(1) per-hit path tracking, O(1) uniqueness check.
///
/// Built through the same per-engine API custom strategies use — the strategy
/// contains its trie as engine state, advanced by its onEdge hook and judged by
/// its decision. The observer mechanism reports every hit; THIS strategy
/// chooses loop immunity (`makeTrieHooks` gates advancement to an edge's first
/// hit per iteration) so loop counts don't lengthen paths. Each parallel
/// engine builds its own trie, so cursors never interleave.
private func makePathTrieEngine<each Input: Codable & Sendable>(
) -> CoverageEngine<repeat each Input> {
    let trie = PathTrie()
    let hooks = makeTrieHooks(trie)

    return CoverageEngine(
        onEdge: hooks.onEdge,
        onReset: hooks.onReset
    ) { sparse, corpus, input, scheduleBytes in
        defer {
            trie.reset()
        }

        guard trie.isUniquePath else {
            return false
        }

        trie.markTerminal()
        corpus.mergeCoverageAndAdd(input: input, scheduleBytes: scheduleBytes, sparse: sparse)
        return true
    }
}

// MARK: - Always Interesting Strategy

/// Always interesting strategy: every input is added unconditionally.
private func makeAlwaysInterestingEngine<each Input: Codable & Sendable>(
) -> CoverageEngine<repeat each Input> {
    CoverageEngine { sparse, corpus, input, scheduleBytes in
        corpus.mergeCoverageAndAdd(input: input, scheduleBytes: scheduleBytes, sparse: sparse)
        return true
    }
}
