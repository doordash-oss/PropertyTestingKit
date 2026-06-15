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

//  Comparison-coverage (value-profile / cmplog) strategy.
//
//  Edge coverage is blind to bugs whose distinguishing condition is a DATA
//  relationship — a de Bruijn `i < c`, a magic-byte compare — because a
//  near-miss input and a witnessing input trace the SAME edges. This strategy
//  adds the signal libFuzzer's value profile (and RedQueen / laf-intel) use:
//  for every instrumented comparison it records the pair
//  `(comparison-site PC, popcount(arg1 ^ arg2))`. As an input nears a boundary
//  the Hamming distance of the operands changes, so new distances at a known
//  site keep surfacing as novelty — a gradient that drives mutation toward the
//  boundary even when the edge set never changes. Unions with edge coverage so
//  it is never weaker than `.newEdge`.
//

extension CoverageStrategy {
    /// Value-profile / comparison-coverage strategy: an input is interesting iff
    /// it produces a `(comparison-site, Hamming-distance-of-operands)` pair this
    /// engine hasn't seen, OR it covers a new edge (union with `.newEdge`).
    ///
    /// Requires the target to be built with `-sanitize-coverage=…,trace-cmp`
    /// (in addition to the usual `edge,pc-table`) so the comparison hooks fire;
    /// without trace-cmp the comparison channel stays silent and this degrades
    /// to plain edge novelty.
    ///
    /// Publishes no culling vocabulary — the pool culls on covered edges. A
    /// value-profile vocabulary would equal this strategy's own acceptance
    /// criterion, and a culling vocabulary equal to acceptance is a tautology
    /// that silently disables culling (see `.hitCountBuckets`).
    ///
    /// - Warning: measured to UNDER-perform `.newEdge` on the de Bruijn
    ///   `shift_var_leq` mutant (stlc): accepting every new `(site, distance)`
    ///   pair floods the corpus and dilutes mutation energy, dropping the solve
    ///   rate (4/8 vs newEdge's 8/8 at a 20s cap) even though it is a strict
    ///   superset of newEdge's acceptance. The comparison operands are better
    ///   spent on input-to-state MUTATION than on acceptance. Kept as the
    ///   measured baseline for that future work; not recommended as a default.
    public static var comparisonCoverage: CoverageStrategy {
        CoverageStrategy(makeEngine: { makeComparisonCoverageEngine() })
    }
}

/// One value-profile feature: the comparison site mixed with the Hamming
/// distance of its operands (FNV-1a). Two comparisons at the same site with
/// operands the same distance apart collide deliberately — that is the feature.
private func comparisonFeature(pc: UInt, hammingDistance: Int) -> UInt64 {
    var h: UInt64 = 1469598103934665603            // FNV-1a offset basis
    h = (h ^ UInt64(truncatingIfNeeded: pc)) &* 1099511628211
    h = (h ^ UInt64(hammingDistance)) &* 1099511628211
    return h
}

/// Comparison-coverage engine. `onCompare` is the measurement half (hash each
/// comparison into this run's value-profile feature set); `decide` the
/// judgement half (interesting iff some feature or some edge is new to this
/// engine). The novelty oracle is the STRATEGY's own per-engine state.
private func makeComparisonCoverageEngine() -> CoverageEngine {
    // One lock for both halves is safe: onCompare, onReset, and decide all run
    // under the per-thread observer gate, so comparisons their own code fires
    // are never dispatched back into onCompare.
    struct ProfileState {
        /// This iteration's value-profile features (cleared on reset/decide).
        var currentRun: Set<UInt64> = []
        /// Engine-lifetime features seen across all accepted-or-not iterations.
        /// Keys are pre-mixed comparisonFeature hashes → no-SipHash set (41n).
        var seenFeatures = FeatureHashSet()
        /// Engine-lifetime edges, for the edge-coverage union.
        var seenEdges = EdgeUnionBitmap()
    }
    let state = SyncBox<ProfileState>(ProfileState())

    return CoverageEngine(
        onCompare: { pc, arg1, arg2, _ in
            let distance = (arg1 ^ arg2).nonzeroBitCount
            let feature = comparisonFeature(pc: pc, hammingDistance: distance)
            state.update { $0.currentRun.insert(feature) }
        },
        onReset: {
            state.update { $0.currentRun.removeAll(keepingCapacity: true) }
        }
    ) { coverage in
        state.update { st in
            defer { st.currentRun.removeAll(keepingCapacity: true) }
            var interesting = false

            // Value-profile novelty: any comparison feature new to this engine.
            for feature in st.currentRun where st.seenFeatures.insert(feature) {
                interesting = true
            }

            // Edge-coverage union: never weaker than .newEdge. The snapshot is
            // the one the evaluator reuses for storage, so reading it is free
            // for accepted inputs (and the cost of the union for rejected ones).
            if let sparse = coverage.materialized() {
                for edge in sparse.indices where st.seenEdges.insert(edge) {
                    interesting = true
                }
            }

            return interesting
        }
    }
}
