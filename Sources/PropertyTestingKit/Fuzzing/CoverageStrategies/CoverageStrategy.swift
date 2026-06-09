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

// MARK: - Re-packing built-ins
//
// The built-in factories themselves live in this directory's per-strategy
// files (PathTrieStrategy.swift, SignatureMatchStrategy.swift, ...).

extension CoverageStrategy {
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
