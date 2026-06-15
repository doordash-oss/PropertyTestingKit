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

//  Tests for the boundaryState strategy + boundaryStateOwnership admission: the
//  joint boundary-state vocabulary. On top of boundaryDistance (per-site
//  gradient + edge union) it accepts/publishes the k-wise SIGN combinations over
//  near-boundary sites, so a novel JOINT side-configuration is interesting and
//  retained even when no edge and no closer distance is new.
//

import Testing
import Foundation
import SanCovHooks
@testable import PropertyTestingKit

@Suite("boundaryState strategy")
struct BoundaryStateStrategyTests {

    /// Fires TWO comparison sites per iteration (so joint sign combinations are
    /// exercisable) through the real evaluator.
    private func makeHarness() -> (
        fire: (_ a: (UInt, UInt64, UInt64), _ b: (UInt, UInt64, UInt64), _ edges: [UInt32]) -> CoverageAcceptance?,
        teardown: () -> Void
    ) {
        let context = SanCovCounters.beginMeasurement()
        let evaluator: CoverageEvaluator<Int> = CoverageStrategy.boundaryState.makeEvaluator()
        evaluator.setup?(context)
        let client = CoverageCountersClient.liveValue
        let corpus = Corpus<Int>()

        let fire: ((UInt, UInt64, UInt64), (UInt, UInt64, UInt64), [UInt32]) -> CoverageAcceptance? = { a, b, edges in
            SanCovCounters.resetCoverage(context)
            for e in edges { var g = e; sancov_dispatch_edge(&g) }
            sancov_dispatch_cmp(a.0, a.1, a.2, 8)
            sancov_dispatch_cmp(b.0, b.1, b.2, 8)
            return evaluator.evaluate(1, nil, context, client, corpus)
        }
        return (fire, { SanCovCounters.endMeasurement(context) })
    }

    @Test("A novel joint sign state is interesting with no new edge and no closer distance")
    func novelSignStateIsInteresting() {
        let h = makeHarness()
        defer { h.teardown() }

        // Iter 1: A@(5,5)=d0/== and B@(5,5)=d0/==, edges {40,41}. New everything.
        #expect(h.fire((0xAA, 5, 5), (0xBB, 5, 5), [40, 41]) != nil)
        // Iter 2: identical — nothing new in any dimension.
        #expect(h.fire((0xAA, 5, 5), (0xBB, 5, 5), [40, 41]) == nil)
        // Iter 3: A unchanged (d0/==), B now (4,5)=d1/< — FARTHER than its seen
        // d0 (no distance novelty) and same edges, but a NEW sign side for B and
        // a NEW joint combination. Interesting via the SIGN dimension alone.
        #expect(h.fire((0xAA, 5, 5), (0xBB, 4, 5), [40, 41]) != nil,
                "a new near-boundary side configuration is interesting on its own")
    }

    @Test("Accepted run publishes the joint sign features (singletons + the pair)")
    func publishesSignFeatures() {
        let h = makeHarness()
        defer { h.teardown() }

        let acc = h.fire((0xAA, 5, 5), (0xBB, 4, 5), [40, 41])
        let signs = try? #require(acc?.boundarySigns)
        let set = Set(signs ?? [])
        // A on side == (1), B on side < (0); both within window 1.
        #expect(set.contains(encodeBoundarySign1(site: UInt64(0xAA), sign: 1)))
        #expect(set.contains(encodeBoundarySign1(site: UInt64(0xBB), sign: 0)))
        #expect(set.contains(encodeBoundarySign2(siteA: UInt64(0xAA), signA: 1,
                                                 siteB: UInt64(0xBB), signB: 0)))
    }

    @Test("a site hit multiple times in one run records every near side it visited")
    func loopAccumulatesNearSides() {
        let h = makeHarness()
        defer { h.teardown() }
        // Site 0xAA fires TWICE this run (a loop straddle): (5,5)=d0/== and
        // (4,5)=d1/< — both within window 1. The mask must hold BOTH sides, not
        // just the one at the closest approach.
        let acc = h.fire((0xAA, 5, 5), (0xAA, 4, 5), [40])
        let signs = Set(acc?.boundarySigns ?? [])
        #expect(signs.contains(encodeBoundarySign1(site: UInt64(0xAA), sign: 1)),
                "the == side it touched")
        #expect(signs.contains(encodeBoundarySign1(site: UInt64(0xAA), sign: 0)),
                "the < side it ALSO touched in the loop")
    }

    @Test("a far hit's side is not recorded even when the site is near at its closest")
    func farSideExcluded() {
        let h = makeHarness()
        defer { h.teardown() }
        // Site 0xAA: closest approach (5,5)=d0/== is within window 1, but it also
        // fired (50,5)=d45/> far from the boundary. The far > must NOT join the
        // mask — only near hits are fragile enough to count.
        let acc = h.fire((0xAA, 5, 5), (0xAA, 50, 5), [40])
        let signs = Set(acc?.boundarySigns ?? [])
        #expect(signs.contains(encodeBoundarySign1(site: UInt64(0xAA), sign: 1)),
                "the near == side")
        #expect(!signs.contains(encodeBoundarySign1(site: UInt64(0xAA), sign: 2)),
                "the far > side does not contribute")
    }

    @Test("boundaryState attaches a comparison observer (like boundaryDistance)")
    func attachesCmpObserver() {
        let context = SanCovCounters.beginMeasurement()
        defer { SanCovCounters.endMeasurement(context) }
        let evaluator: CoverageEvaluator<Int> = CoverageStrategy.boundaryState.makeEvaluator()
        evaluator.setup?(context)
        #expect(sancov_context_get_cmp_recorder_for_testing(context.rawContext) != nil)
    }
}

@Suite("boundaryState admission")
struct BoundaryStateAdmissionTests {
    private func outcome(
        edges: [UInt32], distances: [UInt64: UInt64], signs: [UInt64]
    ) -> PoolIterationOutcome {
        PoolIterationOutcome(
            source: .generated,
            newCoverage: SparseCoverage(indices: edges),
            boundaryDistances: distances,
            boundarySigns: signs)
    }

    @Test("An input owning only a novel sign combination earns residence")
    func signOnlyAdmits() {
        let core = WeightedPoolCore(
            admission: .boundaryStateOwnership, policies: [],
            burstLength: 1, focusOnInsert: false)
        // First sighting of sign 7: admitted on the sign alone (no edges, and the
        // single boundary it also carries is its own, but sign suffices).
        #expect(core.observe(outcome(edges: [], distances: [:], signs: [7])) == 0)
        // Re-seen sign, nothing else new: rejected.
        #expect(core.observe(outcome(edges: [], distances: [:], signs: [7])) == nil)
        // A new sign combination: admitted again.
        #expect(core.observe(outcome(edges: [], distances: [:], signs: [8])) == 1)
    }
}
