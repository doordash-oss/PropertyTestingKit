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

//  The joint boundary-state vocabulary: three-valued comparison sign and its
//  k-wise combinations across near-boundary sites.

import Testing
@testable import PropertyTestingKit

@Suite("Boundary sign encoding")
struct BoundarySignTests {

    @Test("sign is three-valued: <, ==, >")
    func threeValued() {
        #expect(boundarySign(3, 5) == 0)   // <
        #expect(boundarySign(5, 5) == 1)   // ==
        #expect(boundarySign(7, 5) == 2)   // >
    }

    @Test("encodings are deterministic across calls")
    func deterministic() {
        #expect(encodeBoundarySign1(site: 100, sign: 1) == encodeBoundarySign1(site: 100, sign: 1))
        #expect(encodeBoundarySign2(siteA: 100, signA: 1, siteB: 200, signB: 2)
                == encodeBoundarySign2(siteA: 100, signA: 1, siteB: 200, signB: 2))
    }

    @Test("singletons distinguish site and sign")
    func singletonDistinct() {
        let a0 = encodeBoundarySign1(site: 100, sign: 0)
        let a1 = encodeBoundarySign1(site: 100, sign: 1)
        let b0 = encodeBoundarySign1(site: 200, sign: 0)
        #expect(a0 != a1, "same site, different side → different feature")
        #expect(a0 != b0, "different site, same side → different feature")
    }

    @Test("pair feature is order-independent (set semantics)")
    func pairUnordered() {
        #expect(encodeBoundarySign2(siteA: 100, signA: 1, siteB: 200, signB: 2)
                == encodeBoundarySign2(siteA: 200, signA: 2, siteB: 100, signB: 1))
    }

    @Test("pair feature distinguishes each member's side")
    func pairDistinct() {
        let base = encodeBoundarySign2(siteA: 100, signA: 1, siteB: 200, signB: 2)
        #expect(base != encodeBoundarySign2(siteA: 100, signA: 1, siteB: 200, signB: 0),
                "B on a different side → different conjunction")
        #expect(base != encodeBoundarySign2(siteA: 100, signA: 0, siteB: 200, signB: 2),
                "A on a different side → different conjunction")
    }

    @Test("singleton and pair namespaces do not collide")
    func namespacesDisjoint() {
        // A degenerate pair (same site twice) must not equal that site's singleton.
        #expect(encodeBoundarySign1(site: 100, sign: 1)
                != encodeBoundarySign2(siteA: 100, signA: 1, siteB: 100, signB: 1))
    }

    @Test("only near-boundary sites participate, and pairs cross them")
    func windowAndPairs() {
        // pc100 @0 and pc200 @1 are within window 1; pc300 @9 is not.
        let feats = boundarySignFeatures(
            perSite: [100: (sign: 1, distance: 0),
                      200: (sign: 0, distance: 1),
                      300: (sign: 2, distance: 9)],
            window: 1, maxSites: 16)
        // 2 participants → 2 singletons + 1 pair = 3 features; pc300 excluded.
        #expect(feats.count == 3)
        #expect(Set(feats).contains(encodeBoundarySign1(site: 100, sign: 1)))
        #expect(Set(feats).contains(encodeBoundarySign1(site: 200, sign: 0)))
        #expect(Set(feats).contains(encodeBoundarySign2(siteA: 100, signA: 1, siteB: 200, signB: 0)))
        #expect(!Set(feats).contains(encodeBoundarySign1(site: 300, sign: 2)))
    }

    @Test("no near-boundary sites → no features")
    func emptyWhenAllFar() {
        let feats = boundarySignFeatures(
            perSite: [100: (sign: 0, distance: 5), 200: (sign: 2, distance: 8)],
            window: 1, maxSites: 16)
        #expect(feats.isEmpty)
    }

    @Test("maxSites caps the participant set to the closest sites")
    func capsToClosest() {
        // 4 sites all within window; cap at 2 → 2 singletons + 1 pair = 3.
        let feats = boundarySignFeatures(
            perSite: [1: (sign: 0, distance: 0), 2: (sign: 1, distance: 0),
                      3: (sign: 2, distance: 1), 4: (sign: 0, distance: 1)],
            window: 5, maxSites: 2)
        #expect(feats.count == 3)
    }
}
