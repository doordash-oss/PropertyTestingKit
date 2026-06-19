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

//  Feature-ownership accounting (libFuzzer's corpus model): every feature is
//  owned by the smallest entry exhibiting it; entries live exactly as long
//  as they own something.
//

/// The ownership state machine behind `PoolAdmission.featureOwnership`.
///
/// A *feature* here is an opaque `UInt64` fact about a run — the strategy's
/// own vocabulary when it publishes one (today only `.pathTrie(gramLength:)`'s
/// path k-grams), the covered edge indices otherwise. The *size* metric orders
/// owners:
/// smaller wins (REDUCE), ties don't steal, so ownership can only ever move
/// to strictly simpler inputs and the churn terminates.
///
/// Entry IDs are assigned sequentially on admission and never reused,
/// mirroring `WeightedPoolCore`'s ID assignment — the two stay aligned
/// because admission is the only path that inserts.
import FuzzCore

struct FeatureOwnershipLedger {
    struct Verdict {
        /// The input claimed ≥ 1 feature and joins the pool.
        let admit: Bool
        /// Entries that lost their last owned feature to this claim.
        let evict: [Int]
        /// How many features this input newly OWNED (0 when not admitted).
        let claimed: Int
    }

    /// Feature → owning entry ID.
    private var featureOwners: [UInt64: Int] = [:]
    /// REDUCE metric per entry at accept (the mutator-measured input size when
    /// available, the covered-edge count otherwise), index == ID.
    private var entrySize: [Int] = []
    /// Features currently owned per entry, index == ID.
    private var entryOwnedCount: [Int] = []

    /// Judge one accepted input: claim what it can, evict the bankrupted.
    mutating func judge(features: [UInt64], size: Int) -> Verdict {
        var claimed: [UInt64] = []
        for feature in features {
            if let owner = featureOwners[feature] {
                if size < entrySize[owner] { claimed.append(feature) }
            } else {
                claimed.append(feature)
            }
        }
        guard !claimed.isEmpty else {
            return Verdict(admit: false, evict: [], claimed: 0)
        }

        let id = entrySize.count
        entrySize.append(size)
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
        return Verdict(admit: true, evict: evicted, claimed: claimed.count)
    }
}
