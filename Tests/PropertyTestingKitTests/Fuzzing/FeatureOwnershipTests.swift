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

//  Feature-ownership culling (libFuzzer's corpus model): every coverage
//  feature is owned by exactly one pool entry — the smallest input that
//  exhibits it. An accepted input joins the pool only by claiming at least
//  one feature (unowned, or stolen from a larger owner — REDUCE); an entry
//  that loses its last feature leaves the pool. Pool size is therefore
//  bounded by the feature space, no matter how chatty the coverage
//  strategy's acceptance is.
//

import Testing
@testable import PropertyTestingKit

// MARK: - Ledger (pure state machine)

@Suite("Feature-ownership ledger")
struct FeatureOwnershipLedgerTests {

    @Test("Unowned features are claimed and the entry is admitted")
    func claimsUnownedFeatures() {
        var ledger = FeatureOwnershipLedger()
        let verdict = ledger.judge(features: [1, 2], size: 2)
        #expect(verdict.admit)
        #expect(verdict.evict.isEmpty)
    }

    @Test("Rejects when every feature is owned by a smaller or equal entry")
    func rejectsWhenAllFeaturesOwned() {
        var ledger = FeatureOwnershipLedger()
        _ = ledger.judge(features: [1, 2], size: 2)        // entry 0 owns {1,2}
        // Same features, LARGER input: nothing claimable.
        let larger = ledger.judge(features: [1, 2], size: 3)
        #expect(!larger.admit)
        // Same features, EQUAL size: ties don't steal.
        let tie = ledger.judge(features: [1, 2], size: 2)
        #expect(!tie.admit)
    }

    @Test("A smaller input steals ownership (REDUCE); the loser keeps its remainder")
    func smallerInputSteals() {
        var ledger = FeatureOwnershipLedger()
        _ = ledger.judge(features: [1, 2, 3], size: 3)     // entry 0 owns {1,2,3}
        let verdict = ledger.judge(features: [1, 2], size: 2)
        #expect(verdict.admit)
        #expect(verdict.evict.isEmpty, "entry 0 still owns {3} — not evicted")
    }

    @Test("Losing the last owned feature evicts the loser")
    func lastLossEvicts() {
        var ledger = FeatureOwnershipLedger()
        _ = ledger.judge(features: [1, 2], size: 3)        // entry 0 owns {1,2}
        let verdict = ledger.judge(features: [1, 2], size: 2)
        #expect(verdict.admit)
        #expect(verdict.evict == [0])
    }

    @Test("Admitted entries take sequential IDs; evicted IDs are never reused")
    func sequentialIDsAcrossEviction() {
        var ledger = FeatureOwnershipLedger()
        _ = ledger.judge(features: [1], size: 2)           // entry 0
        _ = ledger.judge(features: [1], size: 1)           // entry 1 evicts 0
        let verdict = ledger.judge(features: [9], size: 1) // entry 2
        #expect(verdict.admit)
        // Entry 2's claim must not collide with the dead entry 0: stealing 9
        // from it would be impossible (unowned), and a later size-1 input on
        // feature 1 must contest entry 1, not entry 0.
        let contest = ledger.judge(features: [1], size: 1)
        #expect(!contest.admit, "tie against the CURRENT owner (entry 1)")
    }
}

// MARK: - Admission wired into the pool core

@Suite("Feature-ownership admission")
struct FeatureOwnershipAdmissionTests {

    private final class Listener: PoolPlugin {
        var removed: [Int] = []
        func handle(event: PoolEvent) -> [PoolAction] {
            if case let .removed(id) = event { removed.append(id) }
            return []
        }
    }

    // White-box scaffolding is shared via `WeightedPoolHarness`; these thin
    // forwards pin the admission to `.featureOwnership` for this suite.
    private func makeCore(
        policies: [any PoolPlugin], generationRatio: Double = 0
    ) -> WeightedPoolCore<Int> {
        WeightedPoolHarness.core(
            admission: .featureOwnership, policies: policies, generationRatio: generationRatio)
    }

    private func accept(_ core: WeightedPoolCore<Int>, edges: [UInt32], parent: Int? = nil) -> Int? {
        WeightedPoolHarness.accept(core, edges: edges, parent: parent)
    }

    private func miss(_ core: WeightedPoolCore<Int>, parent: Int? = nil) {
        WeightedPoolHarness.miss(core, parent: parent)
    }

    @Test("Redundant accepts are not admitted: no residence")
    func redundantAcceptIgnored() {
        let core = makeCore(policies: [], generationRatio: 0)

        #expect(accept(core, edges: [1, 2]) == 0)
        // Strategy says interesting again, same features, same size: rejected.
        #expect(accept(core, edges: [1, 2]) == nil)
        // No new entry: there is still only the one to draw.
        #expect(core.decide() == .mutate(id: 0))
    }

    @Test("REDUCE: a smaller input evicts the bankrupted owner from the draw set")
    func reduceEvictsLoser() {
        let listener = Listener()
        let core = makeCore(policies: [listener], generationRatio: 0)

        #expect(accept(core, edges: [1, 2, 3]) == 0)
        // Smaller input covering a subset: admitted, steals {1,2}; entry 0
        // survives on {3}.
        #expect(accept(core, edges: [1, 2]) == 1)
        #expect(listener.removed.isEmpty)

        // Smaller still, stealing {3}: entry 0 loses its last feature.
        #expect(accept(core, edges: [3]) == 2)
        #expect(listener.removed == [0])

        // Entry 0 is never drawn again.
        var drawn = Set<Int>()
        for _ in 0..<100 {
            if case let .mutate(id) = core.decide() {
                drawn.insert(id)
                miss(core, parent: id)
            } else {
                miss(core)
            }
        }
        #expect(!drawn.contains(0))
        #expect(drawn == [1, 2])
    }
}
