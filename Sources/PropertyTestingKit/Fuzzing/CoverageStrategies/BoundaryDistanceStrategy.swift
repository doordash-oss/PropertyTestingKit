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
    // The per-comparison hot path writes into `accumulator` (a concrete
    // open-addressing PC -> (minDistance, signMask) map); the engine-lifetime
    // acceptance oracle lives in `state`, touched only once per iteration in
    // `decide`/`distances`/`signs`. Splitting them keeps Swift.Dictionary +
    // generic `SyncBox.update<A>` off the comparison hot path (Finding 41).
    let accumulator = BoundarySiteAccumulator()

    struct DistanceState {
        /// Engine-lifetime lowest distance ever seen per site — the monotone
        /// acceptance oracle.
        var bestDistance: [UInt64: UInt64] = [:]
        /// Engine-lifetime edges, for the edge-coverage union.
        var seenEdges = EdgeUnionBitmap()
        /// Engine-lifetime sign combinations seen — the acceptance oracle for
        /// the sign dimension (only populated when `emitSigns`). Keys are
        /// pre-mixed feature hashes, so a no-SipHash FeatureHashSet (Finding 41n).
        var seenSigns = FeatureHashSet()
        /// The last accepted run's per-site closest approach, handed to the pool.
        var lastAccepted: [BoundarySiteAccumulator.Site] = []
        /// The last accepted run's sign-combination features, handed to the pool
        /// (computed once in `decide`, returned by the `boundarySigns` closure).
        var lastSignFeatures: [UInt64] = []
        /// Reused near-site selection buffer for `boundarySignFeatures` — kept in
        /// state so the per-iteration feature build allocates nothing on its
        /// participant-selection/sort path (Finding 41k).
        var signScratch: [BoundarySiteAccumulator.Site] = []
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
        accumulator.record(pc: site, distance: distance, nearBit: nearBit)
    }
    let onReset: @Sendable () -> Void = {
        accumulator.reset()
    }
    let distancesClosure: @Sendable () -> [UInt64: UInt64] = {
        state.update { st in
            var d: [UInt64: UInt64] = [:]
            d.reserveCapacity(st.lastAccepted.count)
            for s in st.lastAccepted { d[s.pc] = s.distance }
            return d
        }
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
        // Drain the per-comparison accumulator once (off the hot path), then
        // reset it for the next run. snapshot/reset fire no comparisons of their
        // own (this module is uninstrumented), so they cannot pollute `sparse`.
        let sites = accumulator.snapshot()
        accumulator.reset()
        return state.update { st in
            var interesting = false

            // Edge-coverage union: never weaker than .newEdge.
            if let sparse {
                for edge in sparse.indices where st.seenEdges.insert(edge) {
                    interesting = true
                }
            }

            // Monotone distance novelty: any site driven strictly closer.
            for s in sites {
                if s.distance < (st.bestDistance[s.pc] ?? .max) {
                    st.bestDistance[s.pc] = s.distance
                    interesting = true
                }
            }

            // Joint sign novelty: any never-before-seen near-boundary side
            // configuration. Without this the sign vocabulary would only ever
            // ride edge/distance-novel runs and could never, on its own, pull a
            // partial witness into the pool.
            var signs: [UInt64] = []
            if emitSigns {
                // Read the per-site sign mask + distance straight from `sites`
                // (no perSite dictionary), into a fresh `signs` array (it is
                // published to the pool below) with a reused selection scratch.
                boundarySignFeatures(
                    sites: sites, maxSites: maxSites,
                    into: &signs, scratch: &st.signScratch)
                for s in signs where st.seenSigns.insert(s) { interesting = true }
            }

            // Publish this run's per-site closest approach + sign features
            // regardless of WHY it was accepted, so an edge-novel input can
            // still claim boundaries and sign states.
            st.lastAccepted = sites
            st.lastSignFeatures = signs
            return interesting
        }
    }
}
