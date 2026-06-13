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

//  Tests for the comparisonCoverage strategy: value-profile (cmplog) novelty.
//  An input is interesting when it produces a (comparison-site, Hamming
//  distance of the operands) pair this engine hasn't seen, OR a new edge. The
//  Hamming-distance gradient is what pulls inputs toward a boundary `i < c`.
//

import Testing
import Foundation
import SanCovHooks
@testable import PropertyTestingKit

@Suite("comparisonCoverage strategy")
struct ComparisonCoverageStrategyTests {

    /// Drives one iteration through the real evaluator: reset, fire edges + one
    /// comparison, then evaluate. Returns whether the input was accepted.
    private func makeHarness() -> (
        fire: (_ pc: UInt, _ a: UInt64, _ b: UInt64, _ edges: [UInt32], _ input: Int) -> Bool,
        teardown: () -> Void
    ) {
        let context = SanCovCounters.beginMeasurement()
        let evaluator: CoverageEvaluator<Int> = CoverageStrategy.comparisonCoverage.makeEvaluator()
        evaluator.setup?(context)
        let client = CoverageCountersClient.liveValue
        let corpus = Corpus<Int>()

        let fire: (UInt, UInt64, UInt64, [UInt32], Int) -> Bool = { pc, a, b, edges, input in
            SanCovCounters.resetCoverage(context)
            for e in edges {
                var g = e
                sancov_dispatch_edge(&g)
            }
            sancov_dispatch_cmp(pc, a, b, 8)
            return evaluator.evaluate(input, nil, context, client, corpus) != nil
        }
        return (fire, { SanCovCounters.endMeasurement(context) })
    }

    @Test("A new (site, Hamming distance) pair is interesting; replaying it is not")
    func newComparisonFeatureIsInteresting() {
        let h = makeHarness()
        defer { h.teardown() }

        // Same edges both passes (so novelty can only come from the comparison).
        let first = h.fire(0xAA, 4, 5, [40, 41], 1)
        let replay = h.fire(0xAA, 4, 5, [40, 41], 2)

        #expect(first, "a never-seen comparison feature is interesting")
        #expect(!replay, "replaying the identical comparison is not interesting")
    }

    @Test("Approaching the boundary (new Hamming distance at the same site) is interesting")
    func boundaryApproachIsInteresting() {
        let h = makeHarness()
        defer { h.teardown() }

        // distance(8 ^ 5) = popcount(1101) = 3, then distance(4 ^ 5) = popcount(1) = 1.
        _ = h.fire(0xBB, 8, 5, [40, 41], 1)         // seed the site
        let closer = h.fire(0xBB, 4, 5, [40, 41], 2) // a new distance at the same site

        #expect(closer, "a new operand distance at a known site is a new value-profile feature")
    }

    @Test("A new edge is interesting even with no new comparison feature (union)")
    func newEdgeIsInterestingViaUnion() {
        let h = makeHarness()
        defer { h.teardown() }

        _ = h.fire(0xCC, 4, 5, [40, 41], 1)           // seed both the site and edges
        let newEdge = h.fire(0xCC, 4, 5, [40, 41, 42], 2) // identical cmp, one new edge

        #expect(newEdge, "comparisonCoverage unions with edge coverage")
    }

    @Test("Neither a new edge nor a new comparison feature is not interesting")
    func nothingNewIsNotInteresting() {
        let h = makeHarness()
        defer { h.teardown() }

        _ = h.fire(0xDD, 4, 5, [40, 41], 1)
        let stale = h.fire(0xDD, 4, 5, [40, 41], 2)

        #expect(!stale, "an input that repeats known edges and a known comparison is rejected")
    }

    @Test("comparisonCoverage uses default edge recording plus a comparison observer")
    func attachesCmpObserverAndDefaultEdgeRecording() {
        let context = SanCovCounters.beginMeasurement()
        defer { SanCovCounters.endMeasurement(context) }

        let evaluator: CoverageEvaluator<Int> = CoverageStrategy.comparisonCoverage.makeEvaluator()
        evaluator.setup?(context)

        #expect(sancov_context_get_recorder_for_testing(context.rawContext) == nil,
                "no edge observer — edges use the default first-hit recorder (covered_indices feed the union)")
        #expect(sancov_context_get_cmp_recorder_for_testing(context.rawContext) != nil,
                "a comparison observer carries the value-profile state")
    }
}
