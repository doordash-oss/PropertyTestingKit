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

//  Tests for composing coverage strategies: CoverageStrategy.compose / .combined
//  builds one engine whose acceptance is the UNION of the substrategies (an
//  input is interesting iff ANY substrategy finds it so) and whose pool
//  vocabularies are the namespaced union of the substrategies'. This is what
//  lets the comparison channel mix-and-match with edge strategies, e.g.
//  `.pathTrie.combined(with: .boundaryDistanceOnly)`.
//

import Testing
import Foundation
import SanCovHooks
@testable import PropertyTestingKit

@Suite("Coverage strategy composition")
struct CoverageStrategyCompositionTests {

    /// Drive one iteration through a composed strategy's real evaluator: reset,
    /// fire edges + one comparison, evaluate. Returns the acceptance (nil when
    /// rejected). Mirrors the BoundaryDistanceStrategy harness.
    private func makeHarness(_ strategy: CoverageStrategy) -> (
        fire: (_ pc: UInt, _ a: UInt64, _ b: UInt64, _ edges: [UInt32]) -> CoverageAcceptance?,
        teardown: () -> Void
    ) {
        let context = SanCovCounters.beginMeasurement()
        let evaluator = strategy.makeEvaluator()
        evaluator.setup?(context)
        let client = CoverageCountersClient.liveValue
        let fire: (UInt, UInt64, UInt64, [UInt32]) -> CoverageAcceptance? = { pc, a, b, edges in
            SanCovCounters.resetCoverage(context)
            for e in edges { var g = e; sancov_dispatch_edge(&g) }
            sancov_dispatch_cmp(pc, a, b, 8)
            return evaluator.evaluate(context, client)
        }
        return (fire, { SanCovCounters.endMeasurement(context) })
    }

    @Test("Composed acceptance is the union: edge novelty OR distance novelty triggers")
    func acceptanceIsUnion() {
        let h = makeHarness(.newEdge.combined(with: .boundaryDistanceOnly))
        defer { h.teardown() }

        // First sighting: new edges AND a first distance — interesting.
        #expect(h.fire(0xAA, 4, 5, [10, 11]) != nil, "new edges + first distance")
        // Same edges, same distance: neither substrategy finds novelty.
        #expect(h.fire(0xAA, 4, 5, [10, 11]) == nil, "nothing new on either axis")
        // Same edges, strictly closer distance: the cmp substrategy triggers.
        #expect(h.fire(0xAA, 5, 5, [10, 11]) != nil, "|5-5|=0 strictly closer (cmp axis)")
        // New edge, same (already-seen) distance: the edge substrategy triggers.
        #expect(h.fire(0xAA, 5, 5, [12]) != nil, "new edge 12 (edge axis)")
    }

    @Test("A composed cmp×edge strategy publishes BOTH vocabularies")
    func publishesBothVocabularies() {
        // pathTrie(gramLength:) publishes path k-gram `features`;
        // boundaryDistanceOnly publishes `boundaryDistances`. The two channels
        // are orthogonal, so a composed engine carries both at once. (Default
        // .pathTrie publishes no features by design — it culls on edges — so the
        // gram-length variant is used here to exercise the feature channel.)
        let h = makeHarness(.pathTrie(gramLength: 2).combined(with: .boundaryDistanceOnly))
        defer { h.teardown() }

        let acc = h.fire(0xCC, 3, 9, [20, 21, 22])
        #expect(acc != nil, "first sighting is interesting")
        #expect(acc?.features?.isEmpty == false, "pathTrie k-gram features present")
        #expect(acc?.boundaryDistances?.isEmpty == false, "boundary distances present")
        #expect(acc?.boundaryDistances?[UInt64(0xCC)] == 6, "site 0xCC distance |3-9|=6")
    }

    @Test("Composition namespaces features so substrategies' raw values can't collide")
    func featuresAreNamespaced() {
        // Two stub substrategies that each always accept and publish the SAME
        // raw feature value. Without namespacing they'd collapse to one feature
        // in the shared ownership space; with it, two distinct features survive.
        func stub(_ v: UInt64) -> CoverageStrategy {
            CoverageStrategy(makeEngine: { CoverageEngine(features: { [v] }) { _ in true } })
        }
        let h = makeHarness(.compose([stub(7), stub(7)]))
        defer { h.teardown() }

        let acc = h.fire(0xDD, 1, 1, [30])
        #expect(acc != nil)
        #expect(acc?.features?.count == 2, "two substrategies → two features, even with equal raw values")
        #expect(Set(acc?.features ?? []).count == 2, "the namespaced features are distinct")
    }

    @Test("A single-element compose is the identity (no namespacing churn)")
    func singleComposeIsIdentity() {
        let h = makeHarness(.compose([.newEdge]))
        defer { h.teardown() }
        #expect(h.fire(0xEE, 1, 2, [40]) != nil)
        #expect(h.fire(0xEE, 1, 2, [40]) == nil, "replay of seen edges is not novel")
    }
}
