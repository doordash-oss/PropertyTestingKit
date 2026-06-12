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
//  and the focus/burst draw state; child PoolPlugins shape membership and
//  weights through owner-mediated actions and hear about every change.
//
//  The core is non-generic (entries are IDs; typed input storage lives in the
//  engine), so these tests drive it hermetically: feed iteration outcomes,
//  assert directives.
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

    private func makeCore(
        policies: [any PoolPlugin] = [],
        burstLength: Int = 16,
        focusOnInsert: Bool = true
    ) -> WeightedPoolCore {
        WeightedPoolCore(
            admission: .everyDiscovery,
            policies: policies,
            burstLength: burstLength,
            focusOnInsert: focusOnInsert
        )
    }

    /// One accepted discovery: source/coverage shaped like the engine's accept path.
    private func accept(
        _ core: WeightedPoolCore, edges: [UInt32], parent: Int? = nil
    ) -> Int? {
        let source: PoolIterationSource = parent.map { .pool(parent: $0) } ?? .generated
        return core.observe(PoolIterationOutcome(
            source: source, newCoverage: SparseCoverage(indices: edges)))
    }

    /// One uninteresting execution attributed to `parent`.
    private func miss(_ core: WeightedPoolCore, parent: Int? = nil) {
        let source: PoolIterationSource = parent.map { .pool(parent: $0) } ?? .generated
        _ = core.observe(PoolIterationOutcome(source: source, newCoverage: nil))
    }

    @Test("Empty pool always directs fresh generation")
    func emptyPoolGeneratesFresh() {
        let core = makeCore()
        for _ in 0..<10 {
            #expect(core.next() == .generate)
        }
    }

    @Test("Admitted discovery becomes the focus for a full burst, then one fresh")
    func admittedDiscoveryFocusBurst() {
        let core = makeCore(burstLength: 4)
        #expect(accept(core, edges: [1, 2]) == 0)

        // Full burst on the new entry...
        for _ in 0..<4 {
            #expect(core.next() == .mutate(id: 0))
            miss(core, parent: 0)
        }
        // ...then exactly one fresh generation...
        #expect(core.next() == .generate)
        miss(core)
        // ...then back to drawing (only one entry to draw).
        #expect(core.next() == .mutate(id: 0))
    }

    @Test("Admitted entries get sequential stable IDs")
    func sequentialIDs() {
        let core = makeCore()
        #expect(accept(core, edges: [1]) == 0)
        #expect(accept(core, edges: [2]) == 1)
        #expect(accept(core, edges: [3]) == 2)
    }

    @Test("Children hear inserted events and their remove actions kill the burst")
    func childRemoveOnInsert() {
        let child = ScriptedPolicy { event in
            if case let .inserted(id, _, _) = event { return [.remove(id: id)] }
            return []
        }
        let core = makeCore(policies: [child], burstLength: 4)

        #expect(accept(core, edges: [1, 2]) == 0)
        #expect(child.events.contains { if case .inserted(0, _, _) = $0 { return true }; return false })
        // The child evicted the only entry (and the focus with it): no burst.
        #expect(core.next() == .generate)
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
        // burstLength 1 + no focus-on-insert: every cycle is draw → mutate → fresh,
        // so draws dominate and the distribution is observable.
        let core = makeCore(policies: [child], burstLength: 1, focusOnInsert: false)
        _ = accept(core, edges: [1])
        _ = accept(core, edges: [2])

        var drawn = Set<Int>()
        for _ in 0..<100 {
            let directive = core.next()
            if case let .mutate(id) = directive {
                drawn.insert(id)
                miss(core, parent: id)
            } else {
                miss(core)
            }
        }
        #expect(drawn == [1])
    }

    @Test("Weighted draw reaches every live entry")
    func drawReachesAllLiveEntries() {
        let core = makeCore(burstLength: 1, focusOnInsert: false)
        _ = accept(core, edges: [1])
        _ = accept(core, edges: [2])

        var drawn = Set<Int>()
        for _ in 0..<200 {
            if case let .mutate(id) = core.next() {
                drawn.insert(id)
                miss(core, parent: id)
            } else {
                miss(core)
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
        let core = makeCore(policies: [child], burstLength: 1, focusOnInsert: false)
        _ = accept(core, edges: [1])
        _ = accept(core, edges: [2])

        var drawn = Set<Int>()
        for _ in 0..<100 {
            if case let .mutate(id) = core.next() {
                drawn.insert(id)
                miss(core, parent: id)
            } else {
                miss(core)
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
