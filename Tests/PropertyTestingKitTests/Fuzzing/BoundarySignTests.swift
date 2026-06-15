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

    @Test("participants are sites with a non-empty near-sign mask; pairs cross them")
    func participantsAndPairs() {
        // pc100 touched ==, pc200 touched <, both near (non-empty mask); pc300
        // was only ever far (empty mask) and does not participate.
        let feats = boundarySignFeatures(
            perSite: [100: (signMask: 0b010, distance: 0),   // {==}
                      200: (signMask: 0b001, distance: 1),   // {<}
                      300: (signMask: 0,     distance: 9)],  // far only
            maxSites: 16)
        // 2 participants → 2 singletons + 1 pair = 3 features; pc300 excluded.
        #expect(feats.count == 3)
        #expect(Set(feats).contains(encodeBoundarySign1(site: 100, sign: 1)))
        #expect(Set(feats).contains(encodeBoundarySign1(site: 200, sign: 0)))
        #expect(Set(feats).contains(encodeBoundarySign2(siteA: 100, signA: 1, siteB: 200, signB: 0)))
        #expect(!Set(feats).contains(encodeBoundarySign1(site: 300, sign: 2)))
    }

    @Test("no participating sites → no features")
    func emptyWhenNoneNear() {
        let feats = boundarySignFeatures(
            perSite: [100: (signMask: 0, distance: 5), 200: (signMask: 0, distance: 8)],
            maxSites: 16)
        #expect(feats.isEmpty)
    }

    @Test("a site that touched multiple near sides emits an atom per side")
    func multiSideSingletons() {
        // A loop straddle: one site landed both < and == near the boundary.
        let feats = boundarySignFeatures(
            perSite: [100: (signMask: 0b011, distance: 0)],  // {<, ==}
            maxSites: 16)
        let set = Set(feats)
        #expect(set.contains(encodeBoundarySign1(site: 100, sign: 0)))
        #expect(set.contains(encodeBoundarySign1(site: 100, sign: 1)))
        #expect(feats.count == 2, "single site → two singletons, no pair")
    }

    @Test("a pair crosses every side combination of the two sites")
    func multiSidePairs() {
        let feats = boundarySignFeatures(
            perSite: [100: (signMask: 0b011, distance: 0),   // {<, ==}
                      200: (signMask: 0b100, distance: 1)],  // {>}
            maxSites: 16)
        let set = Set(feats)
        // 3 singletons: A<, A==, B>
        #expect(set.contains(encodeBoundarySign1(site: 100, sign: 0)))
        #expect(set.contains(encodeBoundarySign1(site: 100, sign: 1)))
        #expect(set.contains(encodeBoundarySign1(site: 200, sign: 2)))
        // 2 pairs: (A<, B>) and (A==, B>)
        #expect(set.contains(encodeBoundarySign2(siteA: 100, signA: 0, siteB: 200, signB: 2)))
        #expect(set.contains(encodeBoundarySign2(siteA: 100, signA: 1, siteB: 200, signB: 2)))
        #expect(feats.count == 5)
    }

    @Test("maxSites caps the participant set to the closest sites")
    func capsToClosest() {
        // 4 participating sites; cap at 2 (the closest) → 2 singletons + 1 pair = 3.
        let feats = boundarySignFeatures(
            perSite: [1: (signMask: 0b001, distance: 0), 2: (signMask: 0b010, distance: 0),
                      3: (signMask: 0b100, distance: 1), 4: (signMask: 0b001, distance: 1)],
            maxSites: 2)
        #expect(feats.count == 3)
    }

    // MARK: - Allocation-light array-based core (the hot decide path)

    @Test("array-based core matches the dict reference and clears the reused buffer")
    func arrayCoreParityAndReuse() {
        typealias Site = BoundarySiteAccumulator.Site
        let sites: [Site] = [
            Site(pc: 100, distance: 0, signMask: 0b011),  // {<, ==}
            Site(pc: 200, distance: 1, signMask: 0b100),  // {>}
            Site(pc: 300, distance: 9, signMask: 0),      // far only — excluded
        ]
        var out: [UInt64] = []
        var scratch: [Site] = []
        boundarySignFeatures(sites: sites, maxSites: 16, into: &out, scratch: &scratch)

        // Same vocabulary as the dict-keyed reference for the same inputs.
        let ref = boundarySignFeatures(
            perSite: [100: (signMask: 0b011, distance: 0),
                      200: (signMask: 0b100, distance: 1),
                      300: (signMask: 0, distance: 9)],
            maxSites: 16)
        #expect(Set(out) == Set(ref))
        #expect(out.count == ref.count)

        // Reusing the buffer clears prior contents (no stale features leak).
        boundarySignFeatures(sites: [], maxSites: 16, into: &out, scratch: &scratch)
        #expect(out.isEmpty)
    }

    @Test("array-based core caps to the closest sites like the dict reference")
    func arrayCoreCaps() {
        typealias Site = BoundarySiteAccumulator.Site
        let sites: [Site] = [
            Site(pc: 1, distance: 0, signMask: 0b001),
            Site(pc: 2, distance: 0, signMask: 0b010),
            Site(pc: 3, distance: 1, signMask: 0b100),
            Site(pc: 4, distance: 1, signMask: 0b001),
        ]
        var out: [UInt64] = []
        var scratch: [Site] = []
        boundarySignFeatures(sites: sites, maxSites: 2, into: &out, scratch: &scratch)
        #expect(out.count == 3)  // 2 closest → 2 singletons + 1 pair
    }
}
