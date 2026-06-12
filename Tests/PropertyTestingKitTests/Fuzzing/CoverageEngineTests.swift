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

//  Tests for the per-engine custom strategy API: `CoverageStrategy(makeEngine:)`
//  builds a fresh `CoverageEngine` — onEdge/onReset hooks plus the decision,
//  sharing one engine's state — once per parallel engine. This is what makes
//  custom stateful strategies (like a user-written pathTrie) correct under
//  parallelism: state created inside `makeEngine` never crosses engines.
//  (The `CoverageStrategy(onEdge:_:)` convenience shares its closures across
//  all engines — stateless hooks only.)
//

import Testing
import SanCovHooks
@testable import PropertyTestingKit

@Suite("Per-engine coverage strategies")
struct CoverageEngineTests {

    @Test("Each evaluator gets its own engine state")
    func perEngineStateIsolation() {
        let context = SanCovCounters.beginMeasurement()
        defer { SanCovCounters.endMeasurement(context) }
        let coverageClient = CoverageCountersClient.liveValue
        let corpus = Corpus<Int>()

        // The engine's state: a per-engine iteration counter. Only the FIRST
        // iteration of EACH engine is "interesting".
        let strategy = CoverageStrategy(makeEngine: {
            let iterations = PropertyTestingKit.SyncBox<Int>(0)
            return CoverageEngine { _ in
                iterations.update { $0 += 1 }
                return iterations.value == 1
            }
        })

        let engine1: CoverageEvaluator<Int> = strategy.makeEvaluator()
        let engine2: CoverageEvaluator<Int> = strategy.makeEvaluator()

        #expect(engine1.evaluate(1, nil, context, coverageClient, corpus) != nil,
                "Engine 1's first iteration")
        #expect(engine1.evaluate(2, nil, context, coverageClient, corpus) == nil,
                "Engine 1's state must persist across its own iterations")
        #expect(engine2.evaluate(3, nil, context, coverageClient, corpus) != nil,
                "Engine 2 must get FRESH state from its own makeEngine call")
    }

    @Test("An engine's onEdge and decide share the same state")
    func onEdgeFeedsSameEngineDecision() {
        let context = SanCovCounters.beginMeasurement()
        defer { SanCovCounters.endMeasurement(context) }
        let coverageClient = CoverageCountersClient.liveValue
        let corpus = Corpus<Int>()

        let strategy = CoverageStrategy(makeEngine: {
            let edges = PropertyTestingKit.SyncBox<Set<UInt32>>([])
            return CoverageEngine(
                onEdge: { edge, _ in edges.update { _ = $0.insert(edge) } },
                { _ in edges.value.contains(21) }
            )
        })

        let evaluator: CoverageEvaluator<Int> = strategy.makeEvaluator()
        evaluator.setup?(context)

        var g21: UInt32 = 21
        sancov_dispatch_edge(&g21)

        #expect(evaluator.evaluate(1, nil, context, coverageClient, corpus) != nil,
                "decide must see the edges its OWN engine's onEdge observed")
    }

    @Test("An engine's onReset fires on coverage reset")
    func engineOnResetFires() {
        let context = SanCovCounters.beginMeasurement()
        defer { SanCovCounters.endMeasurement(context) }

        let resets = PropertyTestingKit.SyncBox<Int>(0)
        let strategy = CoverageStrategy(makeEngine: {
            CoverageEngine(
                onEdge: { _, _ in },
                onReset: { resets.update { $0 += 1 } },
                { _ in false }
            )
        })

        let evaluator: CoverageEvaluator<Int> = strategy.makeEvaluator()
        evaluator.setup?(context)
        SanCovCounters.resetCoverage(context)

        #expect(resets.value == 1, "resetCoverage must reach the engine's onReset")
    }

    /// The forcing function for "no privileged strategies": newEdge expressed
    /// purely through public API, validated against real dispatch.
    @Test("A user can express the newEdge strategy through the public API")
    func userBuiltNewEdgeStrategy() {
        let context = SanCovCounters.beginMeasurement()
        defer { SanCovCounters.endMeasurement(context) }
        let coverageClient = CoverageCountersClient.liveValue
        let corpus = Corpus<Int>()

        let strategy = CoverageStrategy(makeEngine: {
            // Novelty state is the STRATEGY's own — no corpus access at all.
            let seen = PropertyTestingKit.SyncBox<Set<UInt32>>([])
            return CoverageEngine { sparse in
                seen.update { seenEdges in
                    var foundNew = false
                    for edge in sparse.indices where seenEdges.insert(edge).inserted {
                        foundNew = true
                    }
                    return foundNew
                }
            }
        })
        let evaluator: CoverageEvaluator<Int> = strategy.makeEvaluator()
        evaluator.setup?(context)

        // Identical instrumented code in both passes, reset through evaluate
        // (see the trie dispatch test for why): pass 1 brings new edges,
        // pass 2 replays exactly the same set.
        func firePass(_ input: Int) -> Bool {
            SanCovCounters.resetCoverage(context)
            var g31: UInt32 = 31
            var g32: UInt32 = 32
            sancov_dispatch_edge(&g31)
            sancov_dispatch_edge(&g32)
            return evaluator.evaluate(input, nil, context, coverageClient, corpus) != nil
        }

        let first = firePass(1)
        let second = firePass(2)

        #expect(first, "First pass covers unseen edges")
        #expect(!second, "An identical replay brings no new edge")
        #expect(corpus.count == 1, "Only the novel run joins the corpus")
    }

    /// Strategies are pure judgement: they never see the corpus or the typed
    /// input. When decide says yes, the ENGINE records the input — with its
    /// coverage and schedule bytes — in the corpus.
    @Test("The engine, not the strategy, records interesting inputs")
    func engineOwnsStorage() {
        let context = SanCovCounters.beginMeasurement()
        defer { SanCovCounters.endMeasurement(context) }
        let coverageClient = CoverageCountersClient.liveValue
        let corpus = Corpus<Int>()

        let strategy = CoverageStrategy { _ in true }
        let evaluator: CoverageEvaluator<Int> = strategy.makeEvaluator()

        let acceptance = evaluator.evaluate(7, [9, 9], context, coverageClient, corpus)

        #expect(acceptance != nil, "An always-true decision is interesting")
        #expect(corpus.count == 1, "The engine records the interesting input")
        #expect(corpus.entries.first?.scheduleBytes == [9, 9],
                "Schedule bytes ride with the entry as a storage concern")
        #expect(corpus.entries.first?.sparseCoverage == acceptance?.sparse,
                "The entry carries the run's judged coverage")
    }

    /// newEdge's novelty oracle is the strategy's OWN per-engine state, not
    /// the corpus: a second engine judging the same edges finds them new for
    /// itself even when the shared corpus already holds them.
    @Test("newEdge novelty state is per-engine, not corpus-owned")
    func newEdgeNoveltyIsPerEngine() {
        let context = SanCovCounters.beginMeasurement()
        defer { SanCovCounters.endMeasurement(context) }
        let coverageClient = CoverageCountersClient.liveValue
        let corpus = Corpus<Int>()

        let strategy = CoverageStrategy.newEdge
        let engine1: CoverageEvaluator<Int> = strategy.makeEvaluator()
        let engine2: CoverageEvaluator<Int> = strategy.makeEvaluator()

        // Identical instrumented code per pass (see the trie dispatch test).
        func firePass(_ evaluator: CoverageEvaluator<Int>, _ input: Int) -> Bool {
            SanCovCounters.resetCoverage(context)
            var g41: UInt32 = 41
            var g42: UInt32 = 42
            sancov_dispatch_edge(&g41)
            sancov_dispatch_edge(&g42)
            return evaluator.evaluate(input, nil, context, coverageClient, corpus) != nil
        }

        #expect(firePass(engine1, 1), "Engine 1: first sight of these edges")
        #expect(!firePass(engine1, 2), "Engine 1: replay brings nothing new")
        #expect(firePass(engine2, 3),
                "Engine 2 judges with its OWN state — the corpus already holding these edges must not decide for it")
    }

    /// The default `.pathTrie`'s decision never reads coverage — its oracle
    /// is its own trie — and rejects the vast majority of iterations. Those
    /// rejects must not pay for a sparse snapshot (a malloc plus two
    /// O(covered-edges) copies per iteration).
    @Test("Decisions that never read coverage take no snapshot")
    func rejectWithoutCoverageReadTakesNoSnapshot() {
        let context = SanCovCounters.MeasurementContext.testInstance()
        let snapshots = PropertyTestingKit.SyncBox<Int>(0)
        let client = CoverageCountersClient(
            snapshotCoveredArraysWithContext: { _ in
                snapshots.update { $0 += 1 }
                return SparseCoverage(indices: [1])
            }
        )
        let corpus = Corpus<Int>()

        let strategy = CoverageStrategy { _ in false }
        let evaluator: CoverageEvaluator<Int> = strategy.makeEvaluator()
        for input in 0..<10 {
            _ = evaluator.evaluate(input, nil, context, client, corpus)
        }

        #expect(snapshots.value == 0,
                "a rejecting decision that never reads coverage must not snapshot")
    }

    /// When the decision does read coverage and accepts, the materialized
    /// snapshot is shared with the corpus add: exactly one per iteration.
    @Test("An accepting run snapshots exactly once")
    func acceptingRunSnapshotsOnce() {
        let context = SanCovCounters.MeasurementContext.testInstance()
        let snapshots = PropertyTestingKit.SyncBox<Int>(0)
        let client = CoverageCountersClient(
            snapshotCoveredArraysWithContext: { _ in
                snapshots.update { $0 += 1 }
                return SparseCoverage(indices: [5])
            }
        )
        let corpus = Corpus<Int>()

        let strategy = CoverageStrategy { coverage in !coverage.indices.isEmpty }
        let evaluator: CoverageEvaluator<Int> = strategy.makeEvaluator()
        let acceptance = evaluator.evaluate(1, nil, context, client, corpus)

        #expect(snapshots.value == 1,
                "the decision's snapshot is reused for the corpus add")
        #expect(corpus.entries.first?.sparseCoverage == acceptance?.sparse,
                "the entry carries the judged coverage")
    }

    /// `decide` may live in instrumented code (a user's test target). Edges it
    /// fires must be recorded in the map but NOT dispatched into the same
    /// engine's `onEdge` — observing them would deadlock any non-reentrant
    /// lock shared between `decide` and `onEdge`, the natural shape for a
    /// stateful custom strategy.
    @Test("Edges fired inside decide are not observed")
    func decideEdgesAreNotObserved() {
        let context = SanCovCounters.beginMeasurement()
        defer { SanCovCounters.endMeasurement(context) }
        let coverageClient = CoverageCountersClient.liveValue
        let corpus = Corpus<Int>()

        let observed = PropertyTestingKit.SyncBox<Set<UInt32>>([])
        let strategy = CoverageStrategy(makeEngine: {
            CoverageEngine(
                onEdge: { edge, _ in observed.update { _ = $0.insert(edge) } },
                { _ in
                    var g99: UInt32 = 99
                    sancov_dispatch_edge(&g99)  // decide's own code covers an edge
                    return true
                }
            )
        })
        let evaluator: CoverageEvaluator<Int> = strategy.makeEvaluator()
        evaluator.setup?(context)

        _ = evaluator.evaluate(1, nil, context, coverageClient, corpus)

        #expect(!observed.value.contains(99),
                "decide's own edges must not re-enter the engine's onEdge")
        let after = try? coverageClient.snapshotCoveredArraysWithContext(context)
        #expect(after?.indices.contains(99) == true,
                "decide's edges are still recorded in the coverage map")
    }

    @Test("A parallel fuzz run builds one engine per parallel engine")
    func makeEngineCalledPerParallelEngine() async throws {
        // Deliberately SHARED across engines: counts makeEngine invocations.
        let engineCount = PropertyTestingKit.SyncBox<Int>(0)
        let strategy = CoverageStrategy(makeEngine: {
            engineCount.update { $0 += 1 }
            return CoverageEngine { _ in false }
        })

        _ = try await fuzzWithMaxIterations(
            maxIterations: 8,
            persistence: .ephemeral,
            coverageStrategy: strategy,
            parallelism: 4
        ) { (_: Int) in }

        #expect(engineCount.value == 4,
                "Each of the 4 parallel engines must build its own CoverageEngine")
    }
}
