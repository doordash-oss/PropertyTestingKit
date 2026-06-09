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

        #expect(engine1.evaluate(1, nil, context, coverageClient, corpus),
                "Engine 1's first iteration")
        #expect(!engine1.evaluate(2, nil, context, coverageClient, corpus),
                "Engine 1's state must persist across its own iterations")
        #expect(engine2.evaluate(3, nil, context, coverageClient, corpus),
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

        #expect(evaluator.evaluate(1, nil, context, coverageClient, corpus),
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
