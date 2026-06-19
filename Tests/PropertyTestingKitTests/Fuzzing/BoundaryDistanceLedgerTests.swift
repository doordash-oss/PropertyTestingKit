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

//  Boundary-distance ownership: an experimental extension of feature
//  ownership. Edge features are still owned by the SMALLEST input (REDUCE);
//  in addition, each comparison-site (pc) is owned by the input that drove its
//  operands CLOSEST together (the lowest |arg1 - arg2|). Lower distance steals,
//  ties don't, so the per-boundary owner can only ever get closer and the
//  churn terminates — the directional analog of REDUCE on the value axis.
//

import Testing
@testable import PropertyTestingKit

@Suite("Boundary-distance ledger")
struct BoundaryDistanceLedgerTests {

    @Test("An unowned boundary is claimed and the entry admitted")
    func claimsUnownedBoundary() {
        var ledger = BoundaryDistanceLedger()
        let verdict = ledger.judge(features: [], size: 1, distances: [100: 8])
        #expect(verdict.admit)
        #expect(verdict.evict.isEmpty)
    }

    @Test("A strictly closer input steals the boundary; a farther or equal one does not")
    func closerSteals() {
        var ledger = BoundaryDistanceLedger()
        _ = ledger.judge(features: [], size: 1, distances: [100: 8])   // entry 0 owns pc100 @ 8
        // Farther: nothing to claim.
        #expect(!ledger.judge(features: [], size: 1, distances: [100: 9]).admit)
        // Equal: ties don't steal.
        #expect(!ledger.judge(features: [], size: 1, distances: [100: 8]).admit)
        // Closer: claims it.
        #expect(ledger.judge(features: [], size: 1, distances: [100: 3]).admit)
    }

    @Test("Losing the last owned boundary evicts the previous owner")
    func lastBoundaryLossEvicts() {
        var ledger = BoundaryDistanceLedger()
        _ = ledger.judge(features: [], size: 1, distances: [100: 8])   // entry 0 owns {pc100}
        let verdict = ledger.judge(features: [], size: 1, distances: [100: 1])
        #expect(verdict.admit)
        #expect(verdict.evict == [0])
    }

    @Test("Edge ownership (REDUCE by size) coexists with boundary ownership")
    func edgesAndBoundariesAreAdditive() {
        var ledger = BoundaryDistanceLedger()
        // entry 0: owns edge 1 (size 3) and pc100 @ 8.
        _ = ledger.judge(features: [1], size: 3, distances: [100: 8])
        // Smaller input claims edge 1 (REDUCE) but is FARTHER on pc100: admitted
        // on the edge alone; entry 0 keeps pc100, so it survives.
        let verdict = ledger.judge(features: [1], size: 2, distances: [100: 9])
        #expect(verdict.admit)
        #expect(verdict.evict.isEmpty, "entry 0 still owns pc100")
    }

    @Test("An entry that owns neither a new edge nor a closer boundary is rejected")
    func noClaimRejected() {
        var ledger = BoundaryDistanceLedger()
        _ = ledger.judge(features: [1], size: 2, distances: [100: 4])   // entry 0
        let verdict = ledger.judge(features: [1], size: 5, distances: [100: 9])
        #expect(!verdict.admit)
    }

    @Test("Both dimensions are additive in one verdict")
    func bothDimensionsAdditive() {
        var ledger = BoundaryDistanceLedger()
        let v = ledger.judge(features: [1], size: 3, distances: [100: 8])
        #expect(v.admit)
        #expect(v.claimed == 2, "1 edge + 1 boundary")
    }

    @Test("Admitted entries take sequential IDs across eviction")
    func sequentialIDs() {
        var ledger = BoundaryDistanceLedger()
        _ = ledger.judge(features: [], size: 1, distances: [100: 8])   // entry 0
        _ = ledger.judge(features: [], size: 1, distances: [100: 1])   // entry 1 evicts 0
        let verdict = ledger.judge(features: [], size: 1, distances: [200: 4]) // entry 2
        #expect(verdict.admit)
        // A later tie on pc100 must contest the CURRENT owner (entry 1), not the
        // dead entry 0.
        #expect(!ledger.judge(features: [], size: 1, distances: [100: 1]).admit)
    }
}

// MARK: - Admission wired into the pool core

@Suite("Boundary-distance admission")
struct BoundaryDistanceAdmissionTests {

    private final class Listener: PoolPlugin {
        var removed: [Int] = []
        func handle(event: PoolEvent) -> [PoolAction] {
            if case let .removed(id) = event { removed.append(id) }
            return []
        }
    }

    /// Drive the white-box `admit` seam with a generated outcome carrying both
    /// edges and per-site boundary distances (the harness's `accept` doesn't
    /// thread distances).
    @discardableResult
    private func admit(
        _ core: WeightedPoolCore<Int>, edges: [UInt32], distances: [UInt64: UInt64]
    ) -> Int? {
        core.admit(
            0, coverage: SparseCoverage(indices: edges),
            boundaryDistances: distances, poolSource: .generated)
    }

    @Test("A strictly closer boundary admits and evicts the bankrupted owner")
    func closerBoundaryEvicts() {
        let listener = Listener()
        let core = WeightedPoolHarness.core(
            admission: .boundaryDistanceOwnership, policies: [listener])

        // Entry 0 owns ONLY pc100 (no edges), so losing it bankrupts it.
        #expect(admit(core, edges: [], distances: [100: 8]) == 0)
        #expect(admit(core, edges: [], distances: [100: 2]) == 1)
        #expect(listener.removed == [0])
    }

    @Test("Edge ownership still earns residence with no closer boundary")
    func edgeRetentionSurvives() {
        let core = WeightedPoolHarness.core(
            admission: .boundaryDistanceOwnership, policies: [])

        #expect(admit(core, edges: [1], distances: [100: 8]) == 0)
        // New edge, FARTHER boundary: admitted on the edge alone.
        #expect(admit(core, edges: [2], distances: [100: 9]) == 1)
        // Nothing new in either dimension: rejected.
        #expect(admit(core, edges: [1, 2], distances: [100: 9]) == nil)
    }
}
