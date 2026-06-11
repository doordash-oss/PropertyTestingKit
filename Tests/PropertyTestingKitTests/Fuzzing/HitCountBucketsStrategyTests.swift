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

//  Tests for the hit-count bucketing strategy (.hitCountBuckets): an input is
//  interesting iff some edge's per-run hit count lands in an AFL++/libFuzzer
//  power-of-two bucket (1, 2, 3, 4-7, 8-15, 16-31, 32-127, 128+) this engine
//  has not yet seen for that edge.
//

import Testing
import SanCovHooks
@testable import PropertyTestingKit

@Suite("Hit-count buckets strategy")
struct HitCountBucketsStrategyTests {

    /// Fire one edge `hits` times and judge the run. Identical instrumented
    /// code per pass (the loop's own edges track `hits` too — by design, that
    /// noise lands in the same buckets as the dispatched edge).
    private func firePass(
        _ evaluator: CoverageEvaluator<Int>,
        edge: UInt32,
        hits: Int,
        input: Int,
        _ context: SanCovCounters.MeasurementContext,
        _ coverageClient: CoverageCountersClient,
        _ corpus: Corpus<Int>
    ) -> Bool {
        SanCovCounters.resetCoverage(context)
        var guardValue = edge
        for _ in 0..<hits {
            sancov_dispatch_edge(&guardValue)
        }
        return evaluator.evaluate(input, nil, context, coverageClient, corpus) != nil
    }

    @Test("First sight of an edge is interesting")
    func firstSightIsInteresting() {
        let context = SanCovCounters.beginMeasurement()
        defer { SanCovCounters.endMeasurement(context) }
        let coverageClient = CoverageCountersClient.liveValue
        let corpus = Corpus<Int>()

        let evaluator: CoverageEvaluator<Int> = CoverageStrategy.hitCountBuckets.makeEvaluator()
        evaluator.setup?(context)

        #expect(firePass(evaluator, edge: 61, hits: 1, input: 1, context, coverageClient, corpus),
                "An unseen edge's first bucket is always new")
        #expect(corpus.count == 1, "The interesting run joins the corpus")
    }

    @Test("An identical replay lands in known buckets and is not interesting")
    func identicalReplayIsNotInteresting() {
        let context = SanCovCounters.beginMeasurement()
        defer { SanCovCounters.endMeasurement(context) }
        let coverageClient = CoverageCountersClient.liveValue
        let corpus = Corpus<Int>()

        let evaluator: CoverageEvaluator<Int> = CoverageStrategy.hitCountBuckets.makeEvaluator()
        evaluator.setup?(context)

        #expect(firePass(evaluator, edge: 62, hits: 1, input: 1, context, coverageClient, corpus),
                "First pass covers unseen buckets")
        #expect(!firePass(evaluator, edge: 62, hits: 1, input: 2, context, coverageClient, corpus),
                "A replay with identical hit counts brings no new bucket — and proves per-run counts reset between iterations")
    }

    @Test("A known edge hit a bucket-crossing number of times is interesting")
    func newBucketOnKnownEdgeIsInteresting() {
        let context = SanCovCounters.beginMeasurement()
        defer { SanCovCounters.endMeasurement(context) }
        let coverageClient = CoverageCountersClient.liveValue
        let corpus = Corpus<Int>()

        let evaluator: CoverageEvaluator<Int> = CoverageStrategy.hitCountBuckets.makeEvaluator()
        evaluator.setup?(context)

        #expect(firePass(evaluator, edge: 63, hits: 1, input: 1, context, coverageClient, corpus),
                "Count 1 = bucket {1}, unseen")
        #expect(firePass(evaluator, edge: 63, hits: 2, input: 2, context, coverageClient, corpus),
                "Count 2 = bucket {2}: a new bucket on a KNOWN edge must be interesting — this is what .newEdge cannot see")
    }

    @Test("Hit counts within an already-seen bucket are not interesting")
    func sameBucketDifferentCountIsNotInteresting() {
        let context = SanCovCounters.beginMeasurement()
        defer { SanCovCounters.endMeasurement(context) }
        let coverageClient = CoverageCountersClient.liveValue
        let corpus = Corpus<Int>()

        let evaluator: CoverageEvaluator<Int> = CoverageStrategy.hitCountBuckets.makeEvaluator()
        evaluator.setup?(context)

        #expect(firePass(evaluator, edge: 64, hits: 4, input: 1, context, coverageClient, corpus),
                "Count 4 = bucket {4-7}, unseen")
        #expect(!firePass(evaluator, edge: 64, hits: 5, input: 2, context, coverageClient, corpus),
                "Count 5 is still bucket {4-7} — only the observed bucket was marked, not a threshold")
        #expect(firePass(evaluator, edge: 64, hits: 2, input: 3, context, coverageClient, corpus),
                "Count 2 = bucket {2} was never observed (buckets below a seen one are not implied)")
    }

    @Test("Bucket novelty state is per-engine")
    func bucketNoveltyIsPerEngine() {
        let context = SanCovCounters.beginMeasurement()
        defer { SanCovCounters.endMeasurement(context) }
        let coverageClient = CoverageCountersClient.liveValue
        let corpus = Corpus<Int>()

        let strategy = CoverageStrategy.hitCountBuckets
        let engine1: CoverageEvaluator<Int> = strategy.makeEvaluator()
        let engine2: CoverageEvaluator<Int> = strategy.makeEvaluator()
        engine1.setup?(context)

        #expect(firePass(engine1, edge: 65, hits: 1, input: 1, context, coverageClient, corpus),
                "Engine 1: first sight")
        #expect(!firePass(engine1, edge: 65, hits: 1, input: 2, context, coverageClient, corpus),
                "Engine 1: replay brings nothing new")

        engine2.setup?(context)
        #expect(firePass(engine2, edge: 65, hits: 1, input: 3, context, coverageClient, corpus),
                "Engine 2 judges with its OWN bucket state — engine 1 having seen these buckets must not decide for it")
    }

    @Test("hitCountBuckets drives a real parallel fuzz run")
    func hitCountBucketsSmokeTest() async throws {
        let result = try await fuzzWithMaxIterations(
            maxIterations: 50,
            persistence: .ephemeral,
            coverageStrategy: .hitCountBuckets,
            parallelism: 2
        ) { (input: Int) in
            // Input-dependent loop so hit counts actually vary across inputs.
            // (.magnitude, not abs(): the fuzzer finds Int.min immediately and
            // abs(Int.min) traps.)
            for _ in 0..<(input.magnitude % 7) {
                blackHole(input)
            }
        }

        #expect(result.failures.isEmpty)
        #expect(!result.corpus.isEmpty,
                "The first input of each engine covers only unseen buckets and must be recorded")
    }
}
