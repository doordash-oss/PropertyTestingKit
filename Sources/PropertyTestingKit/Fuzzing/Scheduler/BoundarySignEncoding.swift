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

//  Encoding for the joint boundary-state vocabulary. Where boundary DISTANCE is
//  a per-site gradient that drives the search toward a comparison's flip point,
//  boundary SIGN captures which SIDE of the flip a run landed on — the
//  three-valued position {<, ==, >} that ordinary edge coverage collapses (the
//  `==` case shares the not-taken branch of `a < b` with `>`). A bug like a
//  `<`-vs-`<=` off-by-one diverges from correct code on EXACTLY the `==` row, so
//  that row is the witness state coverage cannot see.
//
//  A single site's sign is not enough: witnesses usually need a CONJUNCTION
//  (site A on its boundary AND site B on a particular side). So the vocabulary
//  is the set of k-wise sign combinations across the run's near-boundary sites —
//  pairwise here, which (per combinatorial-testing results) catches the large
//  majority of interaction states while staying O(sites^2) rather than the
//  intractable 3^n full product. Discovering a novel combination is what the
//  pool retains, so it can hold and cross partial witnesses toward the joint one.
//

/// Three-valued position of a comparison's operands: `<` → 0, `==` → 1, `>` → 2.
/// Unsigned compare (matches `absoluteDifference` in the distance half); the
/// integer-boundary bugs this targets compare small non-negative magnitudes.
func boundarySign(_ a: UInt64, _ b: UInt64) -> UInt64 {
    a < b ? 0 : (a == b ? 1 : 2)
}

/// Process-stable mix (splitmix64 finalizer). Deliberately NOT `Swift.Hasher`,
/// which is per-process seeded — features must hash identically across engines
/// and runs so ownership is comparable.
private func mix(_ x: UInt64) -> UInt64 {
    var z = x &+ 0x9E37_79B9_7F4A_7C15
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
}

// Domain tags keep the 1-wise and 2-wise namespaces disjoint, so a singleton
// feature can never alias a pair feature.
private let signTag1: UInt64 = 0x5347_4E31_0000_0001 // "SGN1"
private let signTag2: UInt64 = 0x5347_4E32_0000_0002 // "SGN2"

/// Singleton feature: "site `s` was on side `sign`".
func encodeBoundarySign1(site s: UInt64, sign: UInt64) -> UInt64 {
    mix(mix(s) ^ (sign &+ 1) ^ signTag1)
}

/// Pairwise feature: the UNORDERED set `{(siteA, signA), (siteB, signB)}` — the
/// joint state "A is on side signA WHILE B is on side signB". Order-independent
/// (the pair is canonicalized) so the same conjunction hashes the same however
/// the two sites were enumerated.
func encodeBoundarySign2(
    siteA: UInt64, signA: UInt64,
    siteB: UInt64, signB: UInt64
) -> UInt64 {
    let h1 = encodeBoundarySign1(site: siteA, sign: signA)
    let h2 = encodeBoundarySign1(site: siteB, sign: signB)
    let lo = min(h1, h2), hi = max(h1, h2)
    return mix((lo &* 0x0000_0100_0000_01B3) ^ hi ^ signTag2)
}

/// Build the run's sign-combination vocabulary from each near-boundary site's
/// `(sign, distance)` at its closest approach. A site participates only when its
/// minimum distance this run is `<= window` — the gradient pulls sites into this
/// window, and only there is the sign "fragile" enough that one mutation flips
/// it. To bound the pairwise blow-up, at most `maxSites` sites (the closest) are
/// crossed. Emits every singleton plus every pair among the participants.
func boundarySignFeatures(
    perSite: [UInt64: (sign: UInt64, distance: UInt64)],
    window: UInt64,
    maxSites: Int
) -> [UInt64] {
    // Closest-first, so the cap keeps the most-fragile sites.
    let near = perSite
        .filter { $0.value.distance <= window }
        .sorted { $0.value.distance < $1.value.distance }
        .prefix(maxSites)
    guard !near.isEmpty else { return [] }

    var features: [UInt64] = []
    features.reserveCapacity(near.count * (near.count + 1) / 2)
    for (i, a) in near.enumerated() {
        features.append(encodeBoundarySign1(site: a.key, sign: a.value.sign))
        for b in near[near.index(near.startIndex, offsetBy: i + 1)...] {
            features.append(encodeBoundarySign2(
                siteA: a.key, signA: a.value.sign,
                siteB: b.key, signB: b.value.sign))
        }
    }
    return features
}
