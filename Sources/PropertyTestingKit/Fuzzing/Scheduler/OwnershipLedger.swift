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

//  The generic ownership ledger: pool-residence bookkeeping, with no notion of
//  WHY a feature was claimed. An evaluator decides — using its own metric (edge
//  size, comparison distance, …) — which features a run wins; the ledger only
//  records the resulting feature → owner roster, reassigns claimed features, and
//  evicts an entry the moment it owns nothing. Splitting the criterion (in the
//  evaluators) from the bookkeeping (here) lets edge coverage, comparison
//  distance, and any future signal share one pool roster.
//

/// A feature is an opaque fact a run exhibited, namespaced by the evaluator that
/// emits it. `domain` keeps distinct signals from colliding — an edge index and
/// a comparison-site `pc` of the same numeric value are different features.
struct Feature: Hashable, Sendable {
    /// The emitting evaluator's namespace (e.g. edges vs. comparison sites).
    let domain: UInt8
    /// The feature's identity within its domain (an edge index, a k-gram hash,
    /// a comparison-site `pc`, …).
    let id: UInt64

    init(domain: UInt8, id: UInt64) {
        self.domain = domain
        self.id = id
    }
}

/// Pool-residence ownership over `Feature`s, metric-agnostic.
///
/// `record` takes the features an evaluator decided this run OWNS (claimed from
/// a prior owner, or previously unowned) and applies them: a fresh entry ID is
/// assigned, each feature is reassigned to it, and any prior owner that loses
/// its last feature is evicted. Entry IDs are sequential and never reused,
/// mirroring `WeightedPoolCore`'s ID assignment — the two stay aligned because
/// admission is the only path that mints an ID.
///
/// Ownership deliberately outlives pool membership: an entry evicted for
/// capacity by `WeightedPoolCore` stays a *ghost owner* of its features here, so
/// re-witnessing a represented feature earns nothing (the evaluator's metric
/// state ghosts in lockstep).
struct OwnershipLedger {
    struct Verdict {
        /// The run claimed ≥ 1 feature and joins the pool.
        let admit: Bool
        /// The entry ID minted for an admitted run; `nil` when rejected (no ID
        /// is consumed).
        let entryID: Int?
        /// Entries that lost their last owned feature to this claim.
        let evict: [Int]
        /// How many features this run newly owned (0 when rejected) — the
        /// draw-weight signal.
        let claimed: Int
    }

    /// Feature → owning entry ID.
    private var featureOwners: [Feature: Int] = [:]
    /// Features currently owned per entry, index == ID.
    private var entryOwnedCount: [Int] = []

    /// Apply the features an evaluator decided this run owns.
    mutating func record(claimed: [Feature]) -> Verdict {
        guard !claimed.isEmpty else {
            return Verdict(admit: false, entryID: nil, evict: [], claimed: 0)
        }

        let id = entryOwnedCount.count
        entryOwnedCount.append(claimed.count)

        var evicted: [Int] = []
        for feature in claimed {
            if let loser = featureOwners[feature] {
                entryOwnedCount[loser] -= 1
                if entryOwnedCount[loser] == 0 {
                    evicted.append(loser)
                }
            }
            featureOwners[feature] = id
        }
        return Verdict(admit: true, entryID: id, evict: evicted, claimed: claimed.count)
    }
}
