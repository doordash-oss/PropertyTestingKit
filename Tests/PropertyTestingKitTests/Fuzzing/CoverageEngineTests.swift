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
//  parallelism: engines never share mutable strategy state.
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
        let strategy = CoverageStrategy<Int>(makeEngine: {
            let iterations = PropertyTestingKit.SyncBox<Int>(0)
            return CoverageEngine { _, _, _, _ in
                iterations.update { $0 += 1 }
                return iterations.value == 1
            }
        })

        let engine1 = strategy.makeEvaluator()
        let engine2 = strategy.makeEvaluator()

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

        let strategy = CoverageStrategy<Int>(makeEngine: {
            let edges = PropertyTestingKit.SyncBox<Set<UInt32>>([])
            return CoverageEngine(
                onEdge: { edge in edges.update { _ = $0.insert(edge) } },
                { _, _, _, _ in edges.value.contains(21) }
            )
        })

        let evaluator = strategy.makeEvaluator()
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
        let strategy = CoverageStrategy<Int>(makeEngine: {
            CoverageEngine(
                onEdge: { _ in },
                onReset: { resets.update { $0 += 1 } },
                { _, _, _, _ in false }
            )
        })

        strategy.makeEvaluator().setup?(context)
        SanCovCounters.resetCoverage(context)

        #expect(resets.value == 1, "resetCoverage must reach the engine's onReset")
    }

    @Test("Corpus.mergeCoverage merges and reports whether any edge was new")
    func corpusMergeCoverageReportsNovelty() {
        let corpus = Corpus<Int>()

        #expect(corpus.mergeCoverage(SparseCoverage(indices: [1, 2, 3])),
                "All edges new")
        #expect(!corpus.mergeCoverage(SparseCoverage(indices: [2, 3])),
                "A subset of seen edges is not new coverage")
        #expect(corpus.mergeCoverage(SparseCoverage(indices: [3, 4])),
                "One unseen edge suffices")
        #expect(!corpus.mergeCoverage(SparseCoverage()),
                "Empty coverage is never new")
    }

    /// The forcing function for "no privileged strategies": newEdge expressed
    /// purely through public API, validated against real dispatch.
    @Test("A user can express the newEdge strategy through the public API")
    func userBuiltNewEdgeStrategy() {
        let context = SanCovCounters.beginMeasurement()
        defer { SanCovCounters.endMeasurement(context) }
        let coverageClient = CoverageCountersClient.liveValue
        let corpus = Corpus<Int>()

        let strategy = CoverageStrategy<Int>(makeEngine: {
            CoverageEngine { sparse, corpus, input, scheduleBytes in
                guard corpus.mergeCoverage(sparse) else { return false }
                corpus.addEntry(input: input, scheduleBytes: scheduleBytes, sparse: sparse)
                return true
            }
        })
        let evaluator = strategy.makeEvaluator()
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

    @Test("A parallel fuzz run builds one engine per parallel engine")
    func makeEngineCalledPerParallelEngine() async throws {
        // Deliberately SHARED across engines: counts makeEngine invocations.
        let engineCount = PropertyTestingKit.SyncBox<Int>(0)
        let strategy = CoverageStrategy<Int>(makeEngine: {
            engineCount.update { $0 += 1 }
            return CoverageEngine { _, _, _, _ in false }
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
