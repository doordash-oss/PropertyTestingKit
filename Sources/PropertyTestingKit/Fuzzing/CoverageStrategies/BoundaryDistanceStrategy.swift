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
        CoverageStrategy(makeEngine: { makeBoundaryEngine() })
    }
}

/// Overflow-safe absolute difference of two comparison operands.
///
/// Computes the wrapped difference ONCE and conditionally negates it, rather
/// than evaluating both `a &- b` and `b &- a` and selecting. `a &- b` and
/// `b &- a` are two's-complement negations of each other, so `b - a == 0 &- (a &- b)`.
/// On arm64 this lowers to `subs` + `cneg` (2 instructions, branchless) vs the
/// `sub` + `subs` + `csel` (3) the two-subtraction ternary emits — and it's on
/// the per-comparison hot path.
private func absoluteDifference(_ a: UInt64, _ b: UInt64) -> UInt64 {
    let d = a &- b
    return a < b ? 0 &- d : d
}

private func makeBoundaryEngine() -> CoverageEngine {
    // The per-comparison hot path writes into `accumulator` (a concrete
    // open-addressing PC -> minDistance map); the engine-lifetime acceptance
    // oracle lives in `state`, touched only once per iteration in
    // `decide`/`distances`. Splitting them keeps Swift.Dictionary + generic
    // `SyncBox.update<A>` off the comparison hot path (Finding 41).
    let accumulator = BoundarySiteAccumulator()

    struct DistanceState {
        /// Engine-lifetime lowest distance ever seen per site — the monotone
        /// acceptance oracle.
        var bestDistance: [UInt64: UInt64] = [:]
        /// Engine-lifetime edges, for the edge-coverage union.
        var seenEdges = EdgeUnionBitmap()
        /// The last accepted run's per-site closest approach, handed to the pool.
        var lastAccepted: [BoundarySiteAccumulator.Site] = []
    }
    let state = UncheckedBox<DistanceState>(DistanceState())

    let onCompare: @Sendable (UInt, UInt64, UInt64, UInt32) -> Void = { pc, arg1, arg2, _ in
        let site = UInt64(truncatingIfNeeded: pc)
        accumulator.record(pc: site, distance: absoluteDifference(arg1, arg2))
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

    return CoverageEngine(
        onCompare: onCompare,
        onReset: onReset,
        boundaryDistances: distancesClosure
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

            // Publish this run's per-site closest approach regardless of WHY it
            // was accepted, so an edge-novel input can still claim boundaries.
            st.lastAccepted = sites
            return interesting
        }
    }
}
