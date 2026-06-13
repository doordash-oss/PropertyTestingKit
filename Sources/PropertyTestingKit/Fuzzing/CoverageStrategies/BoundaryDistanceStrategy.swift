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
        CoverageStrategy(makeEngine: { makeBoundaryDistanceEngine() })
    }
}

/// Overflow-safe absolute difference of two comparison operands.
private func absoluteDifference(_ a: UInt64, _ b: UInt64) -> UInt64 {
    a > b ? a &- b : b &- a
}

private func makeBoundaryDistanceEngine() -> CoverageEngine {
    // One lock for all halves is safe: onCompare, onReset, decide, and the
    // distances closure all run under the per-thread observer gate, so
    // comparisons their own code fires are never dispatched back into onCompare.
    struct DistanceState {
        /// This iteration's lowest distance per comparison site (cleared on
        /// reset and after each decision).
        var currentRun: [UInt64: UInt64] = [:]
        /// Engine-lifetime lowest distance ever seen per site — the monotone
        /// acceptance oracle.
        var bestDistance: [UInt64: UInt64] = [:]
        /// Engine-lifetime edges, for the edge-coverage union.
        var seenEdges: Set<UInt32> = []
        /// The last accepted run's per-site minimum, handed to the pool.
        var lastAccepted: [UInt64: UInt64] = [:]
    }
    let state = SyncBox<DistanceState>(DistanceState())

    return CoverageEngine(
        onCompare: { pc, arg1, arg2, _ in
            let site = UInt64(truncatingIfNeeded: pc)
            let distance = absoluteDifference(arg1, arg2)
            state.update { st in
                if let seen = st.currentRun[site] {
                    if distance < seen { st.currentRun[site] = distance }
                } else {
                    st.currentRun[site] = distance
                }
            }
        },
        onReset: {
            state.update { $0.currentRun.removeAll(keepingCapacity: true) }
        },
        boundaryDistances: { state.update { $0.lastAccepted } }
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
            for (site, distance) in st.currentRun {
                if distance < (st.bestDistance[site] ?? .max) {
                    st.bestDistance[site] = distance
                    interesting = true
                }
            }

            // Publish this run's per-site minimum regardless of WHY it was
            // accepted, so an edge-novel input can still claim boundaries.
            st.lastAccepted = st.currentRun
            return interesting
        }
    }
}
