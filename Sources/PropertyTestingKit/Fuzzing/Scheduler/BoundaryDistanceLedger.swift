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

//  Boundary-distance ownership (experimental). Adds a directional, value-axis
//  ownership dimension on top of edge ownership: each comparison site (pc) is
//  owned by the input that drove its operands closest together.
//

/// The ownership state machine behind `PoolAdmission.boundaryDistanceOwnership`.
///
/// Three ownership dimensions share one entry roster:
/// - **Edges** (the `features` vocabulary): owned by the SMALLEST input
///   exhibiting them, exactly as `FeatureOwnershipLedger` does (REDUCE; ties
///   don't steal).
/// - **Boundaries** (comparison-site `pc`s, the `distances` vocabulary): owned
///   by the input with the LOWEST `|arg1 - arg2|` at that site. A strictly
///   closer input steals; ties don't. Distance can only decrease, so the
///   churn terminates the same way REDUCE does — the value-axis gradient that
///   drives the search toward a comparison's flip point.
/// - **Sign combinations** (the `signFeatures` vocabulary, empty unless the
///   strategy publishes them): owned by DISCOVERY — the first input to exhibit
///   a given near-boundary sign-combination owns it and is never stolen (a
///   combination is a qualitative state, not a quantity, so there is no
///   "closer"). This is what retains and crosses partial witnesses toward the
///   joint state the bug needs. `boundaryDistanceOwnership` passes none (the
///   dimension stays inert); `boundaryStateOwnership` passes them.
///
/// An entry is admitted iff it claims at least one feature in ANY dimension,
/// and is evicted when it loses its last owned feature across all three.
/// Capacity eviction (handled by `WeightedPoolCore`) leaves ghost owners, same
/// as edge ownership — a represented feature stays represented.
struct BoundaryDistanceLedger {
    struct Verdict {
        let admit: Bool
        let evict: [Int]
        /// How many features (edges + boundaries) this input newly OWNED.
        let claimed: Int
    }

    /// Edge feature → owning entry ID.
    private var edgeOwners: [UInt64: Int] = [:]
    /// Comparison site (pc) → owning entry ID.
    private var boundaryOwners: [UInt64: Int] = [:]
    /// Comparison site (pc) → the current owner's distance (its presence
    /// mirrors `boundaryOwners`, so reading it answers "is this pc owned?").
    private var boundaryDistance: [UInt64: UInt64] = [:]
    /// Sign-combination feature → owning entry ID (discovery; never stolen).
    private var signOwners: [UInt64: Int] = [:]
    /// REDUCE metric per entry (covered-edge count or real size at accept).
    private var entrySize: [Int] = []
    /// Features currently owned per entry across ALL THREE dimensions.
    private var entryOwnedCount: [Int] = []

    mutating func judge(
        features: [UInt64],
        size: Int,
        distances: [UInt64: UInt64],
        signFeatures: [UInt64] = []
    ) -> Verdict {
        var claimedEdges: [UInt64] = []
        for feature in features {
            if let owner = edgeOwners[feature] {
                if size < entrySize[owner] { claimedEdges.append(feature) }
            } else {
                claimedEdges.append(feature)
            }
        }

        var claimedBoundaries: [(pc: UInt64, distance: UInt64)] = []
        for (pc, distance) in distances {
            if let current = boundaryDistance[pc] {
                if distance < current { claimedBoundaries.append((pc, distance)) }
            } else {
                claimedBoundaries.append((pc, distance))
            }
        }

        // Sign combinations are discovery-owned: only never-seen ones are
        // claims (a qualitative state has no "closer"). Dedup so a run that
        // emits the same combination twice claims it once.
        var claimedSigns: [UInt64] = []
        var seenThisRun = Set<UInt64>()
        for feature in signFeatures where seenThisRun.insert(feature).inserted {
            if signOwners[feature] == nil { claimedSigns.append(feature) }
        }

        let totalClaims = claimedEdges.count + claimedBoundaries.count + claimedSigns.count
        guard totalClaims > 0 else {
            return Verdict(admit: false, evict: [], claimed: 0)
        }

        let id = entrySize.count
        entrySize.append(size)
        entryOwnedCount.append(totalClaims)

        var evicted: [Int] = []
        for feature in claimedEdges {
            if let loser = edgeOwners[feature] {
                entryOwnedCount[loser] -= 1
                if entryOwnedCount[loser] == 0 { evicted.append(loser) }
            }
            edgeOwners[feature] = id
        }
        for (pc, distance) in claimedBoundaries {
            if let loser = boundaryOwners[pc] {
                entryOwnedCount[loser] -= 1
                if entryOwnedCount[loser] == 0 { evicted.append(loser) }
            }
            boundaryOwners[pc] = id
            boundaryDistance[pc] = distance
        }
        // Discovery ownership: no incumbent to bankrupt, so signs never evict.
        for feature in claimedSigns {
            signOwners[feature] = id
        }
        return Verdict(admit: true, evict: evicted, claimed: totalClaims)
    }
}
