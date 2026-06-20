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

// MARK: - REDUCE behavior (edge evaluator composed with the generic ledger)

/// `featureOwnership` is now the edge evaluator (the REDUCE criterion) composed
/// with the metric-agnostic `OwnershipLedger` (the roster). This helper composes
/// them exactly as the admission does, so these pin the REDUCE behavior that used
/// to live in the single `FeatureOwnershipLedger.judge`.
private struct ReduceJudge {
    var edges = EdgeOwnershipEvaluator()
    var ledger = OwnershipLedger()
    mutating func callAsFunction(_ features: [UInt64], _ size: Int) -> OwnershipLedger.Verdict {
        ledger.record(claimed: edges.claims(edges: features, size: size))
    }
}

@Suite("Feature-ownership (edge evaluator + ledger)")
struct FeatureOwnershipLedgerTests {

    @Test("Unowned features are claimed and the entry is admitted")
    func claimsUnownedFeatures() {
        var judge = ReduceJudge()
        let verdict = judge([1, 2], 2)
        #expect(verdict.admit)
        #expect(verdict.evict.isEmpty)
    }

    @Test("Rejects when every feature is owned by a smaller or equal entry")
    func rejectsWhenAllFeaturesOwned() {
        var judge = ReduceJudge()
        _ = judge([1, 2], 2)                   // entry 0 owns {1,2}
        #expect(!judge([1, 2], 3).admit)       // LARGER: nothing claimable
        #expect(!judge([1, 2], 2).admit)       // EQUAL: ties don't steal
    }

    @Test("A smaller input steals ownership (REDUCE); the loser keeps its remainder")
    func smallerInputSteals() {
        var judge = ReduceJudge()
        _ = judge([1, 2, 3], 3)                // entry 0 owns {1,2,3}
        let verdict = judge([1, 2], 2)
        #expect(verdict.admit)
        #expect(verdict.evict.isEmpty, "entry 0 still owns {3} — not evicted")
    }

    @Test("Losing the last owned feature evicts the loser")
    func lastLossEvicts() {
        var judge = ReduceJudge()
        _ = judge([1, 2], 3)                   // entry 0 owns {1,2}
        let verdict = judge([1, 2], 2)
        #expect(verdict.admit)
        #expect(verdict.evict == [0])
    }

    @Test("Admitted entries take sequential IDs; evicted IDs are never reused")
    func sequentialIDsAcrossEviction() {
        var judge = ReduceJudge()
        #expect(judge([1], 2).entryID == 0)    // entry 0
        #expect(judge([1], 1).entryID == 1)    // entry 1 evicts 0
        let verdict = judge([9], 1)            // entry 2
        #expect(verdict.entryID == 2)
        // A later size-1 input on feature 1 must contest the CURRENT owner
        // (entry 1), not the dead entry 0.
        #expect(!judge([1], 1).admit, "tie against the CURRENT owner (entry 1)")
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
