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

//  Boundary-distance strategy (experimental). The acceptance/publishing half of
//  boundary-distance ownership: accept inputs that get a comparison's operands
//  CLOSER than seen, and publish the run's per-site minimum |arg1 - arg2| for
//  the pool's `boundaryDistanceOwnership` admission to cull on.
//

extension CoverageStrategy {
    /// Comparison-distance strategy: an input is interesting iff it drives some
    /// comparison site's operands strictly closer together than this engine has
    /// seen (lower `|arg1 - arg2|`), OR it covers a new edge (union with
    /// `.newEdge`). It publishes the run's per-site minimum distance as its
    /// pool vocabulary, so `PoolAdmission.boundaryDistanceOwnership` retains, per
    /// site, the single closest witness.
    ///
    /// Unlike `.comparisonCoverage` (value-profile acceptance, which keeps every
    /// *novel* distance — including ones FARTHER from the boundary — and bloats
    /// the corpus), acceptance here is monotone: only a strict improvement
    /// counts. The metric is the absolute numeric difference, not Hamming
    /// distance, so it is a true gradient on the integer line (`8` vs `7` is
    /// Hamming-4 but numeric-1).
    ///
    /// Requires the target to be built with `-sanitize-coverage=…,trace-cmp`;
    /// without it the comparison channel stays silent and this degrades to
    /// plain edge novelty.
    public static var boundaryDistance: CoverageStrategy {
        CoverageStrategy(makeEngine: { makeBoundaryEngine(emitSigns: false, window: 0, maxSites: 0) })
    }

    /// Comparison-distance (as `.boundaryDistance`) PLUS a joint boundary-STATE
    /// vocabulary: alongside the per-site distance gradient, it publishes the
    /// k-wise three-valued SIGN combinations over the run's near-boundary sites
    /// (sites whose closest approach this run was within `window`). Pairs with
    /// `PoolAdmission.boundaryStateOwnership`, which retains, by discovery, each
    /// novel joint side-configuration — so the pool holds partial witnesses and
    /// crosses them toward the conjunction a bug needs (the `==`-row state edge
    /// coverage collapses; see Findings 35/37). Distance approaches the
    /// boundary; sign retains the distinct states once there.
    ///
    /// `window` selects which sites are "fragile" enough to play the sign game
    /// (default 1: on-boundary and one step off — tight, for integer/index
    /// boundaries). `maxSites` caps the pairwise blow-up to the closest sites.
    public static func boundaryState(window: UInt64 = 1, maxSites: Int = 16) -> CoverageStrategy {
        CoverageStrategy(makeEngine: { makeBoundaryEngine(emitSigns: true, window: window, maxSites: maxSites) })
    }

    /// `.boundaryState` with default window/cap.
    public static var boundaryState: CoverageStrategy { boundaryState() }
}

/// Overflow-safe absolute difference of two comparison operands.
private func absoluteDifference(_ a: UInt64, _ b: UInt64) -> UInt64 {
    a > b ? a &- b : b &- a
}

private func makeBoundaryEngine(emitSigns: Bool, window: UInt64, maxSites: Int) -> CoverageEngine {
    // One lock for all halves is safe: onCompare, onReset, decide, and the
    // distances/signs closures all run under the per-thread observer gate, so
    // comparisons their own code fires are never dispatched back into onCompare.
    struct DistanceState {
        /// This iteration's closest approach per comparison site — the lowest
        /// distance, plus the SIGN MASK of every side `{<, ==, >}` the site
        /// landed on while *within `window`* (so a loop that straddles the
        /// boundary records every near side it visited, not just the one at its
        /// tightest hit). Cleared on reset and after each decision.
        var currentRun: [UInt64: (distance: UInt64, signMask: UInt8)] = [:]
        /// Engine-lifetime lowest distance ever seen per site — the monotone
        /// acceptance oracle.
        var bestDistance: [UInt64: UInt64] = [:]
        /// Engine-lifetime edges, for the edge-coverage union.
        var seenEdges: Set<UInt32> = []
        /// Engine-lifetime sign combinations seen — the acceptance oracle for
        /// the sign dimension (only populated when `emitSigns`).
        var seenSigns: Set<UInt64> = []
        /// The last accepted run's per-site closest approach, handed to the pool.
        var lastAccepted: [UInt64: (distance: UInt64, signMask: UInt8)] = [:]
        /// The last accepted run's sign-combination features, handed to the pool
        /// (computed once in `decide`, returned by the `boundarySigns` closure).
        var lastSignFeatures: [UInt64] = []
    }
    let state = SyncBox<DistanceState>(DistanceState())

    // Hoisted with explicit types: the optional-closure ternary inline in the
    // initializer overwhelmed the type-checker ("failed to produce diagnostic").
    let onCompare: @Sendable (UInt, UInt64, UInt64, UInt32) -> Void = { pc, arg1, arg2, _ in
        let site = UInt64(truncatingIfNeeded: pc)
        let distance = absoluteDifference(arg1, arg2)
        // Only near hits (within `window`) are "fragile" enough to flip with one
        // mutation, so only they join the side mask. The mask bit is the side
        // this hit landed on; OR accumulates across every hit of the site this
        // run. (For `.boundaryDistance`, emitSigns is false → no sign work.)
        let nearBit: UInt8 = (emitSigns && distance <= window) ? UInt8(1 << boundarySign(arg1, arg2)) : 0
        state.update { st in
            if var cur = st.currentRun[site] {
                if distance < cur.distance { cur.distance = distance }
                cur.signMask |= nearBit
                st.currentRun[site] = cur
            } else {
                st.currentRun[site] = (distance, nearBit)
            }
        }
    }
    let onReset: @Sendable () -> Void = {
        state.update { $0.currentRun.removeAll(keepingCapacity: true) }
    }
    let distancesClosure: @Sendable () -> [UInt64: UInt64] = {
        state.update { $0.lastAccepted.mapValues { approach in approach.distance } }
    }
    let signsClosure: (@Sendable () -> [UInt64])? =
        emitSigns ? ({ @Sendable in state.update { $0.lastSignFeatures } }) : nil

    return CoverageEngine(
        onCompare: onCompare,
        onReset: onReset,
        boundaryDistances: distancesClosure,
        boundarySigns: signsClosure
    ) { coverage in
        // Snapshot the run's edges BEFORE any bookkeeping below: this closure
        // runs in (gated) instrumented code, so its own dict work fires edges
        // that land in the map. Materializing first caches the snapshot the
        // edge union (and storage) read, so our bookkeeping can't pollute it —
        // the same first-read discipline `.newEdge` follows.
        let sparse = coverage.materialized()
        return state.update { st in
            defer { st.currentRun.removeAll(keepingCapacity: true) }
            var interesting = false

            // Edge-coverage union: never weaker than .newEdge.
            if let sparse {
                for edge in sparse.indices where st.seenEdges.insert(edge).inserted {
                    interesting = true
                }
            }

            // Monotone distance novelty: any site driven strictly closer.
            for (site, approach) in st.currentRun {
                if approach.distance < (st.bestDistance[site] ?? .max) {
                    st.bestDistance[site] = approach.distance
                    interesting = true
                }
            }

            // Joint sign novelty: any never-before-seen near-boundary side
            // configuration. Without this the sign vocabulary would only ever
            // ride edge/distance-novel runs and could never, on its own, pull a
            // partial witness into the pool.
            var signs: [UInt64] = []
            if emitSigns {
                signs = boundarySignFeatures(
                    perSite: st.currentRun.mapValues { (signMask: $0.signMask, distance: $0.distance) },
                    maxSites: maxSites)
                for s in signs where st.seenSigns.insert(s).inserted { interesting = true }
            }

            // Publish this run's per-site closest approach + sign features
            // regardless of WHY it was accepted, so an edge-novel input can
            // still claim boundaries and sign states.
            st.lastAccepted = st.currentRun
            st.lastSignFeatures = signs
            return interesting
        }
    }
}
