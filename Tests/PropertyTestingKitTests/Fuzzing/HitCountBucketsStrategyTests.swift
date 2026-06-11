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

    // MARK: - Engine unit tests (no dispatch)
    //
    // The bucket table is pure logic, so it gets exhaustive hermetic coverage:
    // the engine's closures are driven by hand — no sancov dispatch, no
    // evaluator, no ambient-edge noise. The integration tests above own the
    // wiring properties (observer routing, per-engine isolation, storage).

    /// One engine, judged by hand: hit `edge` `hits` times, then decide.
    /// The decision never reads the view, so a stub client suffices.
    private static func makeJudge() -> (_ edge: UInt32, _ hits: Int) -> Bool {
        let engine = CoverageStrategy.hitCountBuckets.makeEngine()
        let context = SanCovCounters.MeasurementContext.testInstance()
        let client = CoverageCountersClient(
            snapshotCoveredArraysWithContext: { _ in SparseCoverage() }
        )
        return { edge, hits in
            engine.onReset?()
            for hit in 0..<hits {
                engine.onEdge?(edge, hit == 0)
            }
            return engine.decide(CoverageView(context: context, client: client))
        }
    }

    /// The AFL++ bucket table as (lowest count, highest count) per bucket.
    private static let bucketBounds: [(lo: Int, hi: Int)] = [
        (1, 1), (2, 2), (3, 3), (4, 7), (8, 15), (16, 31), (32, 127), (128, 1_000_000)
    ]

    @Test("A bucket's lowest and highest counts judge as the same bucket",
          arguments: bucketBounds)
    func bucketBoundsShareABucket(bounds: (lo: Int, hi: Int)) {
        let judge = Self.makeJudge()
        #expect(judge(70, bounds.lo), "Count \(bounds.lo): first sight of the bucket")
        #expect(!judge(70, bounds.hi),
                "Count \(bounds.hi) must land in the same bucket as \(bounds.lo)")
    }

    @Test("Adjacent buckets are distinct at their boundary",
          arguments: zip(bucketBounds.dropLast(), bucketBounds.dropFirst()))
    func adjacentBucketsAreDistinctAtTheBoundary(
        lower: (lo: Int, hi: Int), upper: (lo: Int, hi: Int)
    ) {
        let judge = Self.makeJudge()
        #expect(judge(71, lower.hi), "Count \(lower.hi): first sight of the lower bucket")
        #expect(judge(71, upper.lo),
                "Count \(upper.lo) must cross into the next bucket — an off-by-one in the bucket table would merge them")
    }

    @Test("decide clears the per-run counts itself")
    func decideClearsPerRunCounts() {
        let engine = CoverageStrategy.hitCountBuckets.makeEngine()
        let context = SanCovCounters.MeasurementContext.testInstance()
        let client = CoverageCountersClient(
            snapshotCoveredArraysWithContext: { _ in SparseCoverage() }
        )
        func judgeOneHit() -> Bool {
            engine.onEdge?(72, true)
            return engine.decide(CoverageView(context: context, client: client))
        }

        #expect(judgeOneHit(), "Count 1: bucket {1} is unseen")
        // No reset between runs: if decide had not cleared the counts, this
        // run would read count 2 — bucket {2}, spuriously interesting.
        #expect(!judgeOneHit(), "Count must be 1 again, not an accumulated 2")
    }

    @Test("onReset clears the per-run counts")
    func onResetClearsPerRunCounts() {
        let judge = Self.makeJudge()  // makeJudge resets before every run

        #expect(judge(73, 1), "Count 1: bucket {1} is unseen")
        // If onReset did not clear, this run would read count 2 — bucket {2},
        // spuriously interesting.
        #expect(!judge(73, 1), "A reset run must judge count 1 again")
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
