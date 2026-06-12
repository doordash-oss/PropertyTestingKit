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

//  Pool capacity: an explicit residence bound, decoupling how finely the
//  vocabulary distinguishes inputs from how many of them may stay.
//

import Testing
@testable import PropertyTestingKit

@Suite("Pool capacity")
struct PoolCapacityTests {

    private final class ScriptedPolicy: PoolPlugin {
        var events: [PoolEvent] = []
        let respond: (PoolEvent) -> [PoolAction]
        init(respond: @escaping (PoolEvent) -> [PoolAction] = { _ in [] }) {
            self.respond = respond
        }
        func handle(event: PoolEvent) -> [PoolAction] {
            events.append(event)
            return respond(event)
        }
    }

    private func accept(
        _ core: WeightedPoolCore, edges: [UInt32], features: [UInt64]? = nil
    ) -> Int? {
        core.observe(PoolIterationOutcome(
            source: .generated,
            newCoverage: SparseCoverage(indices: edges),
            features: features))
    }

    private func makeCore(
        admission: PoolAdmission = .everyDiscovery,
        policies: [any PoolPlugin] = [],
        capacity: Int?
    ) -> WeightedPoolCore {
        WeightedPoolCore(
            admission: admission, policies: policies,
            burstLength: 1, focusOnInsert: false, capacity: capacity)
    }

    @Test("Admission past capacity evicts a resident, never the newcomer")
    func capacityEvictsResidentNotNewcomer() {
        let listener = ScriptedPolicy()
        let core = makeCore(policies: [listener], capacity: 2)
        #expect(accept(core, edges: [1]) == 0)
        #expect(accept(core, edges: [2]) == 1)
        #expect(accept(core, edges: [3]) == 2, "the newcomer is always admitted")

        let removed = listener.events.compactMap { event -> Int? in
            if case let .removed(id) = event { return id }
            return nil
        }
        #expect(removed == [1], "uniform weights: the newest RESIDENT yields (elders anchor the pool)")

        // Only 0 and 2 are ever drawn.
        var drawn = Set<Int>()
        for _ in 0..<100 {
            if case let .mutate(id) = core.next() { drawn.insert(id) }
        }
        #expect(drawn == [0, 2])
    }

    @Test("The lowest-weight resident is the capacity victim")
    func lowestWeightEvicted() {
        let weigher = ScriptedPolicy { event in
            if case .inserted(1, _, _) = event {
                return [.setWeight(id: 0, 5.0), .setWeight(id: 1, 0.1)]
            }
            return []
        }
        let core = makeCore(policies: [weigher], capacity: 2)
        #expect(accept(core, edges: [1]) == 0)
        #expect(accept(core, edges: [2]) == 1)
        #expect(accept(core, edges: [3]) == 2)

        let removed = weigher.events.compactMap { event -> Int? in
            if case let .removed(id) = event { return id }
            return nil
        }
        #expect(removed == [1], "entry 1 carries the lowest weight")
    }

    @Test("A capacity-evicted owner's claims stay closed (no revolving door)")
    func capacityEvictionKeepsGhostOwnership() {
        let core = makeCore(admission: .featureOwnership, capacity: 1)
        #expect(accept(core, edges: [1, 2], features: [100]) == 0)
        // B's admission (new feature 200) evicts A for capacity.
        #expect(accept(core, edges: [3, 4], features: [200]) == 1)
        // C re-witnesses A's feature at the SAME size. The ghost owner keeps
        // the claim — releasing evicted claims was measured (fsub probe) to
        // turn the bounded pool into a FIFO of re-claimers: admission jumped
        // from 48% to 91% of accepts and throughput fell further.
        #expect(accept(core, edges: [5, 6], features: [100]) == nil)
        // A strictly SMALLER witness still steals from the ghost.
        #expect(accept(core, edges: [5], features: [100]) == 2)
    }

    @Test("REDUCE evictions free room before an innocent is chosen")
    func reduceEvictionFreesRoomFirst() {
        let listener = ScriptedPolicy()
        let core = makeCore(
            admission: .featureOwnership, policies: [listener], capacity: 2)
        #expect(accept(core, edges: [1, 2], features: [100]) == 0)
        #expect(accept(core, edges: [3, 4], features: [200]) == 1)
        // Smaller input steals 0's only feature: REDUCE evicts 0, the pool is
        // back under capacity, and entry 1 must survive.
        #expect(accept(core, edges: [5], features: [100]) == 2)

        let removed = listener.events.compactMap { event -> Int? in
            if case let .removed(id) = event { return id }
            return nil
        }
        #expect(removed == [0], "no capacity victim on top of the REDUCE one")
    }

    @Test("Unbounded by default")
    func unboundedByDefault() {
        let core = WeightedPoolCore(
            admission: .everyDiscovery, policies: [],
            burstLength: 1, focusOnInsert: false)
        for i in 0..<300 {
            #expect(accept(core, edges: [UInt32(i)]) == i)
        }
    }
}
