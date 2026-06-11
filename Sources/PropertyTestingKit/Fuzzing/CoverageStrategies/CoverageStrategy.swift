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

import EdgeHooks

/// Determines how the fuzzer decides if an input is "interesting" (worth adding to the corpus).
///
/// A strategy is **pure judgement** over coverage: its decision sees only the
/// run's `SparseCoverage` and returns whether the input was interesting.
/// Storage is the engine's job — when the decision says yes, the engine records
/// the input (with its coverage and schedule bytes) in the corpus. Strategies
/// never see the corpus, the typed input, or schedule bytes, which also makes
/// every strategy — built-in or custom — usable under any input pack and under
/// schedule fuzzing.
///
/// PropertyTestingKit ships four built-in strategies as static factories:
/// - `.signatureMatch`: Exact edge-set matching via inverted index. Zero false positives.
/// - `.newEdge`: Any previously-unseen edge is interesting. Matches AFL/libFuzzer.
/// - `.pathTrie` (default): Trie-based ordered-path tracking. O(1) per edge hit and uniqueness check.
/// - `.alwaysInteresting`: Every input is added. Useful for testing without coverage.
///
/// Custom strategies use the same surface (see `init(makeEngine:)`):
/// ```swift
/// fuzz(coverageStrategy: CoverageStrategy { sparse in isNovel(sparse) }) { ... }
/// ```
public struct CoverageStrategy: Sendable {
    /// Builds a fresh engine bundle (with fresh per-engine state, e.g. a new
    /// trie/index). Called once per parallel fuzz engine so engines never share
    /// mutable coverage state. Every strategy, built-in or custom, goes through
    /// this same surface.
    let makeEngine: @Sendable () -> CoverageEngine

    /// Build a custom strategy from a decision over the run's coverage.
    ///
    /// `decide` is called once per fuzz iteration with the edges the run
    /// covered. Return `true` if the input was interesting — the engine then
    /// records it in the corpus.
    ///
    /// - Parameter onEdge: The strategy's per-edge function — the *measurement*
    ///   half (what each edge hit does), paired with `decide`'s *judgement*
    ///   half. Called on EVERY hit of edges that route to the engine's
    ///   measurement context, loop re-executions included — gating (loop
    ///   immunity, dedup, hit-count bucketing) is your strategy's decision, the
    ///   way `.pathTrie` gates itself to first hits. The context co-owns the
    ///   closure's state, so capture freely. `nil` (the default) leaves the
    ///   plain map recording.
    /// - Note: `onEdge` and `decide` are shared across parallel engines. Keep
    ///   them free of mutable state, or use `init(makeEngine:)` to give each
    ///   engine its own.
    public init(
        onEdge: (@Sendable (UInt32) -> Void)? = nil,
        _ decide: @escaping CoverageDecision
    ) {
        self.init(makeEngine: { CoverageEngine(onEdge: onEdge, decide) })
    }

    /// Build a strategy whose per-edge hooks and decision hold fresh
    /// per-engine state.
    ///
    /// `makeEngine` is called once per parallel engine, so the state its
    /// closures capture is engine-isolated by construction — exactly how the
    /// built-in `.pathTrie` allocates a fresh trie per engine. This is the form
    /// to use for any stateful strategy:
    /// ```swift
    /// CoverageStrategy(makeEngine: {
    ///     let trie = PathTrie()                       // this engine's state
    ///     return CoverageEngine(
    ///         onEdge: { edge in trie.advance(edge) }, // measurement half
    ///         onReset: { trie.reset() }
    ///     ) { _ in                                    // judgement half
    ///         defer { trie.reset() }
    ///         guard trie.isUniquePath else { return false }
    ///         trie.markTerminal()
    ///         return true
    ///     }
    /// })
    /// ```
    public init(makeEngine: @escaping @Sendable () -> CoverageEngine) {
        self.makeEngine = makeEngine
    }
}

extension CoverageStrategy {
    /// Compile this strategy for one fuzz engine at the engine's input pack:
    /// build a fresh engine bundle and wrap it in the evaluator the state
    /// machine drives. The wrapper owns storage — when the strategy's decision
    /// says yes, the input is recorded in the corpus with its coverage and
    /// schedule bytes. Strategies themselves never touch the corpus.
    func makeEvaluator<each Input: Codable & Sendable>() -> CoverageEvaluator<repeat each Input> {
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
            // `decide` runs under the observer gate for the same reason
            // `onEdge`/`onReset` do: it may live in instrumented code, so
            // edges its own execution fires must not dispatch synchronously
            // into the engine's `onEdge` — sharing a non-reentrant lock
            // between the two would deadlock. The judged snapshot is already
            // taken, and decide's edges still land in the map (cleared by the
            // next iteration's reset).
            let gated = sancov_observer_enter()
            let interesting = engine.decide(sparse)
            if gated { sancov_observer_exit() }
            guard interesting else {
                return nil
            }
            // Judgement said yes; recording the input is the engine's job,
            // not the strategy's.
            corpus.mergeCoverageAndAdd(input: input, scheduleBytes: scheduleBytes, sparse: sparse)
            return sparse
        })
    }
}

/// A coverage-interestingness decision: pure judgement over the edges the run
/// covered. Return `true` if the input was interesting — the engine records it
/// in the corpus (with its coverage and schedule bytes); strategies never see
/// storage.
public typealias CoverageDecision = @Sendable (_ sparse: SparseCoverage) -> Bool

/// A closure that decides if an input is interesting and records it.
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
