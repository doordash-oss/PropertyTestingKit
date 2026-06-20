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

//  Evaluators own the ownership *criterion* and the metric state; they emit the
//  features a run wins as opaque `Feature`s for the generic `OwnershipLedger`.
//  The edge evaluator owns by smallest input (REDUCE); the boundary evaluator
//  owns by lowest comparison distance, breaking ties toward the smaller input.
//

import Testing
@testable import PropertyTestingKit

@Suite("Edge ownership evaluator")
struct EdgeOwnershipEvaluatorTests {

    @Test("an unowned edge is claimed, in the edge domain")
    func unownedClaimed() {
        var e = EdgeOwnershipEvaluator()
        let claims = e.claims(edges: [10, 20], size: 5)
        #expect(claims == [Feature(domain: FeatureDomain.edge, id: 10),
                           Feature(domain: FeatureDomain.edge, id: 20)])
    }

    @Test("a strictly smaller input steals an owned edge; equal or larger does not")
    func reduceSteal() {
        var e = EdgeOwnershipEvaluator()
        _ = e.claims(edges: [10], size: 5)                  // entry A owns 10 at size 5
        #expect(e.claims(edges: [10], size: 5).isEmpty)     // tie: no steal
        #expect(e.claims(edges: [10], size: 6).isEmpty)     // larger: no steal
        #expect(e.claims(edges: [10], size: 4)              // smaller: steal
                == [Feature(domain: FeatureDomain.edge, id: 10)])
        // The best is now 4; a 5 can no longer steal.
        #expect(e.claims(edges: [10], size: 5).isEmpty)
    }
}

@Suite("Boundary distance evaluator")
struct BoundaryDistanceEvaluatorTests {

    @Test("an unseen comparison site is claimed, in the comparison domain")
    func unseenClaimed() {
        var e = BoundaryDistanceEvaluator()
        let claims = e.claims(distances: [0xAB: 100], size: 5)
        #expect(claims == [Feature(domain: FeatureDomain.comparison, id: 0xAB)])
    }

    @Test("a strictly closer distance steals the site; a farther one does not")
    func closerSteals() {
        var e = BoundaryDistanceEvaluator()
        _ = e.claims(distances: [0xAB: 100], size: 5)        // owns pc at distance 100
        #expect(e.claims(distances: [0xAB: 150], size: 5).isEmpty)   // farther: no
        #expect(e.claims(distances: [0xAB: 80], size: 5)             // closer: yes
                == [Feature(domain: FeatureDomain.comparison, id: 0xAB)])
    }

    @Test("on equal distance the smaller input steals; equal or larger does not")
    func tieBreakBySize() {
        var e = BoundaryDistanceEvaluator()
        _ = e.claims(distances: [0xAB: 80], size: 5)         // owns pc at distance 80, size 5
        #expect(e.claims(distances: [0xAB: 80], size: 5).isEmpty)    // same distance, same size
        #expect(e.claims(distances: [0xAB: 80], size: 6).isEmpty)    // same distance, larger
        #expect(e.claims(distances: [0xAB: 80], size: 4)             // same distance, smaller: steal
                == [Feature(domain: FeatureDomain.comparison, id: 0xAB)])
    }
}
