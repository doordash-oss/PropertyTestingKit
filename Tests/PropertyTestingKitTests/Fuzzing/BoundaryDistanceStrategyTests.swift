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

//  Tests for the boundaryDistance strategy: an input is interesting when it
//  drives some comparison site's operands STRICTLY CLOSER than this engine has
//  seen (lower |arg1 - arg2|), OR covers a new edge. It publishes the run's
//  per-site minimum distance so the pool can cull on boundary ownership.
//

import Testing
import Foundation
import SanCovHooks
@testable import PropertyTestingKit

@Suite("boundaryDistance strategy")
struct BoundaryDistanceStrategyTests {

    /// Drives one iteration through the real evaluator: reset, fire edges + a
    /// single comparison, evaluate. Mirrors the proven-deterministic
    /// `comparisonCoverage` harness (one `dispatch_cmp`, no array loop) so
    /// real-code coverage is identical across identical-shape fires. Returns
    /// the acceptance (nil when rejected).
    private func makeHarness() -> (
        fire: (_ pc: UInt, _ a: UInt64, _ b: UInt64, _ edges: [UInt32], _ input: Int) -> CoverageAcceptance?,
        teardown: () -> Void
    ) {
        let context = SanCovCounters.beginMeasurement()
        let evaluator: CoverageEvaluator<Int> = CoverageStrategy.boundaryDistance.makeEvaluator()
        evaluator.setup?(context)
        let client = CoverageCountersClient.liveValue
        let corpus = Corpus<Int>()

        let fire: (UInt, UInt64, UInt64, [UInt32], Int) -> CoverageAcceptance? = { pc, a, b, edges, input in
            SanCovCounters.resetCoverage(context)
            for e in edges {
                var g = e
                sancov_dispatch_edge(&g)
            }
            sancov_dispatch_cmp(pc, a, b, 8)
            return evaluator.evaluate(input, nil, context, client, corpus)
        }
        return (fire, { SanCovCounters.endMeasurement(context) })
    }

    @Test("A strictly closer distance at a site is interesting; replaying it is not")
    func closerDistanceIsInteresting() {
        let h = makeHarness()
        defer { h.teardown() }

        // Identical-shape fires (same edges, same cmp call, same input): only
        // the dispatched operand distance varies, so any acceptance after the
        // first comes from the distance gradient, not real-code noise.
        #expect(h.fire(0xAA, 4, 5, [40, 41], 1) != nil, "first sighting of pc 0xAA @ |4-5|=1")
        #expect(h.fire(0xAA, 4, 5, [40, 41], 1) == nil, "same distance, same edges: nothing new")
        #expect(h.fire(0xAA, 5, 5, [40, 41], 1) != nil, "|5-5|=0 is strictly closer")
    }

    @Test("A farther distance at a known site is NOT interesting (monotone, unlike value profile)")
    func fartherDistanceIsNotInteresting() {
        let h = makeHarness()
        defer { h.teardown() }

        _ = h.fire(0xBB, 5, 5, [40, 41], 1)        // pc 0xBB @ 0
        #expect(h.fire(0xBB, 0, 9, [40, 41], 1) == nil,
                "|0-9|=9 is farther than the seen 0 — earns nothing")
    }

    @Test("Published distance is the absolute numeric difference, overflow-safe")
    func publishesAbsoluteDifference() {
        let h = makeHarness()
        defer { h.teardown() }

        // The absolute NUMERIC difference (not Hamming): |0 - 2^40| = 2^40.
        // Hamming distance here is 1, so a 2^40 result proves it is the numeric
        // gradient.
        let inRange = h.fire(0xDC, 0, 1 << 40, [40, 41], 1)
        #expect(inRange?.boundaryDistances?[UInt64(0xDC)] == (1 << 40))

        // A near-full-width difference must not trap (the `b &- a` path) and is
        // stored exactly — the value word holds the whole 64-bit distance, no
        // packing, no saturation. (A distance of exactly UInt64.max coincides
        // with the "no hit yet" sentinel, so it can never read as strictly
        // closer; a sub-maximal value exercises the full-width storage.)
        let extreme = h.fire(0xDD, 1, .max, [40, 41], 1)
        #expect(extreme?.boundaryDistances?[UInt64(0xDD)] == UInt64.max - 1,
                "|1 - UInt64.max| computed and stored without overflow")
    }

    @Test("A new edge is interesting via the union even with no closer distance")
    func newEdgeIsInterestingViaUnion() {
        let h = makeHarness()
        defer { h.teardown() }

        _ = h.fire(0xEE, 4, 5, [40, 41], 1)
        let acc = h.fire(0xEE, 4, 5, [40, 41, 42], 1)  // identical cmp, one new edge
        #expect(acc != nil, "boundaryDistance unions with edge coverage")
        // An edge-only accept still publishes the run's distances so the
        // ledger can claim boundaries on it.
        #expect(acc?.boundaryDistances?[UInt64(0xEE)] == 1)
    }

    @Test("boundaryDistance uses default edge recording plus a comparison observer")
    func attachesCmpObserverAndDefaultEdgeRecording() {
        let context = SanCovCounters.beginMeasurement()
        defer { SanCovCounters.endMeasurement(context) }

        let evaluator: CoverageEvaluator<Int> = CoverageStrategy.boundaryDistance.makeEvaluator()
        evaluator.setup?(context)

        #expect(sancov_context_get_recorder_for_testing(context.rawContext) == nil,
                "no edge observer — edges use the default first-hit recorder for the union")
        #expect(sancov_context_get_cmp_recorder_for_testing(context.rawContext) != nil,
                "a comparison observer carries the distance state")
    }
}
