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

import Foundation

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

/// Walk the ≤3 set bits of a sign mask (bit 0 → `<`, bit 1 → `==`, bit 2 → `>`,
/// i.e. `1 << boundarySign(...)`) WITHOUT allocating an array. `@inline(__always)`
/// with a non-escaping body so the closure stays on the stack — this is the hot
/// decide path (Finding 41k: the old `sides(of:) -> [UInt64]` allocated per site
/// in nested loops every iteration).
@inline(__always)
private func forEachSide(of mask: UInt8, _ body: (UInt64) -> Void) {
    if mask & 0b001 != 0 { body(0) }
    if mask & 0b010 != 0 { body(1) }
    if mask & 0b100 != 0 { body(2) }
}

/// Build the run's sign-combination vocabulary from each site's near-boundary
/// SIGN MASK — the set of sides `{<, ==, >}` it landed on while within the
/// window (the caller, `onCompare`, applies the window per hit, so a far-away
/// loop iteration never joins the mask). A site participates iff its mask is
/// non-empty; that is equivalent to "its closest approach this run was within
/// the window," but carrying the full set means a loop that straddles the
/// boundary contributes EVERY near side it visited, not just the one at its
/// tightest hit. To bound the blow-up, at most `maxSites` sites (the closest)
/// are crossed.
///
/// Emits, per participant, one singleton per side in its mask; and per pair of
/// participants, the CROSS-PRODUCT of their sides — every joint side-config this
/// input is primed to reach. This over-approximates co-occurrence (two sites'
/// sides may have held at different loop iterations), which is intentional: the
/// pool wants to retain a seed that has already driven each site near its flip,
/// because it is a short mutation away from the simultaneous conjunction.
func boundarySignFeatures(
    sites: [BoundarySiteAccumulator.Site],
    maxSites: Int,
    into features: inout [UInt64],
    scratch: inout [BoundarySiteAccumulator.Site]
) {
    // Both buffers are reused across decide iterations — clear, keep capacity.
    features.removeAll(keepingCapacity: true)
    scratch.removeAll(keepingCapacity: true)
    // Participants = sites with a non-empty near-sign mask. Read straight from
    // the `sites` array — no perSite dictionary round-trip (Finding 41k).
    for s in sites where s.signMask != 0 { scratch.append(s) }
    guard !scratch.isEmpty else { return }
    // Closest-first, so the cap keeps the most-fragile sites.
    scratch.sort { $0.distance < $1.distance }
    let n = min(scratch.count, maxSites)

    if signBlowupEnabled {
        var sizes: [Int] = []
        sizes.reserveCapacity(n)
        for i in 0..<n { sizes.append(scratch[i].signMask.nonzeroBitCount) }
        recordSignBlowup(sizes: sizes)
    }

    for i in 0..<n {
        let a = scratch[i]
        forEachSide(of: a.signMask) { sa in
            features.append(encodeBoundarySign1(site: a.pc, sign: sa))
        }
        for j in (i + 1)..<n {
            let b = scratch[j]
            forEachSide(of: a.signMask) { sa in
                forEachSide(of: b.signMask) { sb in
                    features.append(encodeBoundarySign2(
                        siteA: a.pc, signA: sa, siteB: b.pc, signB: sb))
                }
            }
        }
    }
}

/// Dict-keyed convenience for tests and non-hot callers: allocates fresh buffers
/// and returns the feature list. The hot per-iteration decide path calls the
/// inout-buffer core above directly to avoid re-allocating every iteration.
func boundarySignFeatures(
    perSite: [UInt64: (signMask: UInt8, distance: UInt64)],
    maxSites: Int
) -> [UInt64] {
    var sites: [BoundarySiteAccumulator.Site] = []
    sites.reserveCapacity(perSite.count)
    for (pc, v) in perSite {
        sites.append(BoundarySiteAccumulator.Site(pc: pc, distance: v.distance, signMask: v.signMask))
    }
    var features: [UInt64] = []
    var scratch: [BoundarySiteAccumulator.Site] = []
    boundarySignFeatures(sites: sites, maxSites: maxSites, into: &features, scratch: &scratch)
    return features
}

// MARK: - Diagnostic: pairwise-vs-full-product vocabulary blowup (PTK_SIGN_BLOWUP)

/// Per-run measurement of how large the sign vocabulary would be under the
/// current pairwise (k≤2) scheme vs. the full combinatorial product across all
/// near-boundary sites. Aggregated process-globally over a real run so the
/// blowup can be read empirically rather than from the 3^n worst-case bound.
/// Only runs with at least one participating site are counted (the others
/// contribute nothing to either scheme).
public struct SignVocabBlowup: Sendable {
    public var runs = 0
    /// near-site participant count `n` → number of runs with that count.
    public var participantHistogram: [Int: Int] = [:]
    /// per-site side-count (1, 2, or 3) → number of site-observations.
    public var sideSizeHistogram: [Int: Int] = [:]
    /// Σ features actually emitted today: singletons + pairwise cross-products.
    public var sumCurrent = 0
    /// Σ of the full *subset* product `Π(1+sᵢ) − 1` — every non-empty partial
    /// side-assignment over the participants (all k from 1…n).
    public var sumFullSubset: Double = 0
    /// Σ of the full *width* product `Π sᵢ` — only the complete n-wide tuples.
    public var sumFullWidth: Double = 0
    public var maxParticipants = 0
    public var maxCurrent = 0
    public var maxFullSubset: Double = 0
    public var maxFullWidth: Double = 0
}

private let signBlowupEnabled: Bool =
    ProcessInfo.processInfo.environment["PTK_SIGN_BLOWUP"] != nil
private let signBlowupStats = SyncBox<SignVocabBlowup>(SignVocabBlowup())

/// Snapshot of the accumulated blowup stats (for a diagnostic harness to print).
public func ptkSignVocabBlowupSnapshot() -> SignVocabBlowup { signBlowupStats.value }
/// Reset the accumulator (call before a measured run).
public func ptkResetSignVocabBlowup() { signBlowupStats.update { $0 = SignVocabBlowup() } }

private func recordSignBlowup(sizes: [Int]) {
    let n = sizes.count
    guard n > 0 else { return }
    var current = 0
    for s in sizes { current += s }                     // singletons
    for i in 0..<n {
        for j in (i + 1)..<n { current += sizes[i] * sizes[j] }   // pairwise
    }
    var fullSubset = 1.0
    var fullWidth = 1.0
    for s in sizes {
        fullSubset *= Double(1 + s)
        fullWidth *= Double(s)
    }
    fullSubset -= 1.0
    signBlowupStats.update { st in
        st.runs += 1
        st.participantHistogram[n, default: 0] += 1
        for s in sizes { st.sideSizeHistogram[s, default: 0] += 1 }
        st.sumCurrent += current
        st.sumFullSubset += fullSubset
        st.sumFullWidth += fullWidth
        st.maxParticipants = max(st.maxParticipants, n)
        st.maxCurrent = max(st.maxCurrent, current)
        st.maxFullSubset = max(st.maxFullSubset, fullSubset)
        st.maxFullWidth = max(st.maxFullWidth, fullWidth)
    }
}
