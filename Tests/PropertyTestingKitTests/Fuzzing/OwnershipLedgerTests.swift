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

//  The generic, metric-agnostic ownership ledger: it records which entry owns
//  which feature, reassigns features the caller (an evaluator) decided this run
//  won, and evicts an entry the moment it owns nothing. It knows NOTHING about
//  why a feature was claimed — no size, no distance. The ownership criterion
//  lives in the evaluators; these tests feed pre-decided claims and pin only the
//  roster/eviction mechanics.
//

import Testing
@testable import PropertyTestingKit

@Suite("Ownership ledger")
struct OwnershipLedgerTests {
    private func f(_ domain: UInt8, _ id: UInt64) -> Feature { Feature(domain: domain, id: id) }

    @Test("claiming unowned features admits the entry and reports the claim count")
    func claimsUnowned() {
        var ledger = OwnershipLedger()
        let v = ledger.record(claimed: [f(0, 1), f(0, 2)])
        #expect(v.admit)
        #expect(v.claimed == 2)
        #expect(v.evict.isEmpty)
    }

    @Test("an empty claim set is rejected and creates no entry")
    func emptyClaimRejected() {
        var ledger = OwnershipLedger()
        let first = ledger.record(claimed: [])
        #expect(!first.admit)
        #expect(first.entryID == nil)
        // The rejected run consumed no ID: the next admission is still entry 0.
        #expect(ledger.record(claimed: [f(0, 1)]).entryID == 0)
    }

    @Test("entry IDs are assigned sequentially across admissions")
    func sequentialIDs() {
        var ledger = OwnershipLedger()
        #expect(ledger.record(claimed: [f(0, 1)]).entryID == 0)
        #expect(ledger.record(claimed: [f(0, 2)]).entryID == 1)
        #expect(ledger.record(claimed: [f(0, 3)]).entryID == 2)
    }

    @Test("reassigning a feature evicts the prior owner only when it loses its last feature")
    func evictsOnLastFeatureLoss() {
        var ledger = OwnershipLedger()
        _ = ledger.record(claimed: [f(0, 1), f(0, 2)])      // entry 0 owns {1,2}
        let keepsOne = ledger.record(claimed: [f(0, 1)])    // entry 1 takes 1; entry 0 keeps 2
        #expect(keepsOne.evict.isEmpty)
        let takesLast = ledger.record(claimed: [f(0, 2)])   // entry 2 takes 2; entry 0 bankrupt
        #expect(takesLast.evict == [0])
    }

    @Test("features in different domains never collide")
    func domainsDoNotCollide() {
        var ledger = OwnershipLedger()
        _ = ledger.record(claimed: [f(0, 7)])               // edge-domain feature 7
        let v = ledger.record(claimed: [f(1, 7)])           // boundary-domain feature 7
        #expect(v.admit)
        #expect(v.evict.isEmpty, "claiming boundary 7 must not steal the edge-domain 7")
    }
}
