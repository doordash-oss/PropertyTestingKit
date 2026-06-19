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

//  The weighted mutation pool: one owner per engine holding entries, weights,
//  and the generation-ratio draw; child PoolPlugins shape membership and
//  weights through owner-mediated actions and hear about every change.
//
//  The core owns its typed inputs (it is generic over the pack), but its draw
//  and admission policy is input-agnostic, so these tests drive it hermetically
//  with a stub Int mutator: feed admissions/misses via `admit`, assert the
//  `decide()` directive. `generationRatio: 0` makes every decision (with a
//  non-empty pool) a draw, so draw-distribution tests are deterministic.
//

import Testing
@testable import PropertyTestingKit

/// Test child: records every event, answers with scripted actions.
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

@Suite("WeightedPool core")
struct WeightedPoolCoreTests {

    // White-box scaffolding is shared via `WeightedPoolHarness`; these thin
    // forwards keep the call sites below readable.
    private func makeCore(
        policies: [any PoolPlugin] = [],
        generationRatio: Double = 0
    ) -> WeightedPoolCore<Int> {
        WeightedPoolHarness.core(policies: policies, generationRatio: generationRatio)
    }

    private func accept(
        _ core: WeightedPoolCore<Int>, edges: [UInt32], parent: Int? = nil
    ) -> Int? {
        WeightedPoolHarness.accept(core, edges: edges, parent: parent)
    }

    private func miss(_ core: WeightedPoolCore<Int>, parent: Int? = nil) {
        WeightedPoolHarness.miss(core, parent: parent)
    }

    @Test("Empty pool always directs fresh generation")
    func emptyPoolGeneratesFresh() {
        // Even at ratio 0 (all-mutation) an empty pool has nothing to draw.
        let core = makeCore(generationRatio: 0)
        for _ in 0..<10 {
            #expect(core.decide() == .generate)
        }
    }

    @Test("Generation ratio 0 always mutates when the pool is non-empty")
    func ratioZeroAlwaysMutates() {
        let core = makeCore(generationRatio: 0)
        #expect(accept(core, edges: [1, 2]) == 0)
        for _ in 0..<20 {
            #expect(core.decide() == .mutate(id: 0))
            miss(core, parent: 0)
        }
    }

    @Test("Generation ratio 1 always generates even with a non-empty pool")
    func ratioOneAlwaysGenerates() {
        let core = makeCore(generationRatio: 1)
        #expect(accept(core, edges: [1, 2]) == 0)
        for _ in 0..<20 {
            #expect(core.decide() == .generate)
            miss(core)
        }
    }

    @Test("Admitted entries get sequential stable IDs")
    func sequentialIDs() {
        let core = makeCore()
        #expect(accept(core, edges: [1]) == 0)
        #expect(accept(core, edges: [2]) == 1)
        #expect(accept(core, edges: [3]) == 2)
    }

    @Test("Children hear inserted events and their remove actions empty the pool")
    func childRemoveOnInsert() {
        let child = ScriptedPolicy { event in
            if case let .inserted(id, _, _) = event { return [.remove(id: id)] }
            return []
        }
        let core = makeCore(policies: [child], generationRatio: 0)

        #expect(accept(core, edges: [1, 2]) == 0)
        #expect(child.events.contains { if case .inserted(0, _, _) = $0 { return true }; return false })
        // The child evicted the only entry: the pool is empty, so generate.
        #expect(core.decide() == .generate)
    }

    @Test("Children hear removed notifications for other policies' evictions")
    func childHearsRemovals() {
        let remover = ScriptedPolicy { event in
            if case .inserted(1, _, _) = event { return [.remove(id: 0)] }
            return []
        }
        let listener = ScriptedPolicy()
        let core = makeCore(policies: [remover, listener])

        _ = accept(core, edges: [1])
        _ = accept(core, edges: [2])
        #expect(listener.events.contains { if case .removed(0) = $0 { return true }; return false })
    }

    @Test("Zero-weighted entries are never drawn")
    func zeroWeightNeverDrawn() {
        let child = ScriptedPolicy { event in
            if case .inserted(0, _, _) = event { return [.setWeight(id: 0, 0.0)] }
            return []
        }
        // Ratio 0: every decision with a non-empty pool is a weighted draw, so
        // the distribution is observable.
        let core = makeCore(policies: [child], generationRatio: 0)
        _ = accept(core, edges: [1])
        _ = accept(core, edges: [2])

        var drawn = Set<Int>()
        for _ in 0..<100 {
            if case let .mutate(id) = core.decide() {
                drawn.insert(id)
                miss(core, parent: id)
            }
        }
        #expect(drawn == [1])
    }

    @Test("Weighted draw reaches every live entry")
    func drawReachesAllLiveEntries() {
        let core = makeCore(generationRatio: 0)
        _ = accept(core, edges: [1])
        _ = accept(core, edges: [2])

        var drawn = Set<Int>()
        for _ in 0..<200 {
            if case let .mutate(id) = core.decide() {
                drawn.insert(id)
                miss(core, parent: id)
            }
        }
        #expect(drawn == [0, 1])
    }

    @Test("Removed entries are never drawn again and IDs do not shift")
    func removedEntryNeverDrawnAgain() {
        var fired = false
        let child = ScriptedPolicy { event in
            if case .willDraw = event, !fired {
                fired = true
                return [.remove(id: 0)]
            }
            return []
        }
        let core = makeCore(policies: [child], generationRatio: 0)
        _ = accept(core, edges: [1])
        _ = accept(core, edges: [2])

        var drawn = Set<Int>()
        for _ in 0..<100 {
            if case let .mutate(id) = core.decide() {
                drawn.insert(id)
                miss(core, parent: id)
            }
        }
        #expect(drawn == [1])
        // A later accept still gets the next sequential ID.
        #expect(accept(core, edges: [3]) == 2)
    }

    @Test("Children observe iteration outcomes with lineage")
    func childSeesIterations() {
        let child = ScriptedPolicy()
        let core = makeCore(policies: [child])
        _ = accept(core, edges: [1])
        miss(core, parent: 0)

        let sawParented = child.events.contains { event in
            if case let .iteration(outcome) = event,
               case .pool(parent: 0) = outcome.source { return true }
            return false
        }
        #expect(sawParented)
    }
}
