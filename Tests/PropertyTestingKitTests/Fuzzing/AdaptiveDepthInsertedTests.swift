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

//  The `.inserted` event must carry the source parent and the number of
//  features the admitted entry newly OWNED, so a draw-weight policy can credit
//  the right parent by how much its mutant found (Score 1 = w ×(1+claimed)).
//

import Testing
@testable import PropertyTestingKit

@Suite("inserted carries parent + claimed")
struct AdaptiveDepthInsertedTests {

    private final class Recorder: PoolPlugin {
        var events: [PoolEvent] = []
        func handle(event: PoolEvent) -> [PoolAction] { events.append(event); return [] }
    }

    @Test("inserted reports source parent and newly-owned feature count")
    func insertedCarriesParentAndClaimed() {
        let rec = Recorder()
        let core = WeightedPoolCore(
            admission: .featureOwnership, policies: [rec],
            burstLength: 16, focusOnInsert: true)

        // Entry 0: generated, owns edges {1,2}.
        _ = core.observe(PoolIterationOutcome(
            source: .generated, newCoverage: SparseCoverage(indices: [1, 2])))
        // Entry 1: a mutant of parent 0, owns one NEW edge {3}.
        _ = core.observe(PoolIterationOutcome(
            source: .pool(parent: 0), newCoverage: SparseCoverage(indices: [3])))

        func inserted(_ id: Int) -> (parent: Int?, claimed: Int)? {
            for e in rec.events {
                if case let .inserted(eid, _, _, parent, claimed) = e, eid == id {
                    return (parent, claimed)
                }
            }
            return nil
        }

        #expect(inserted(0)?.parent == nil)       // generated → no parent
        #expect(inserted(0)?.claimed == 2)        // claimed {1,2}
        #expect(inserted(1)?.parent == 0)         // mutant of entry 0
        #expect(inserted(1)?.claimed == 1)        // claimed {3}
    }
}
