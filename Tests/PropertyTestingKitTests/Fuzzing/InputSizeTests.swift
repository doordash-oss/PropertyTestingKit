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

//  The real input-size metric: mutators that know their value's size feed it
//  to the pool, so REDUCE and capacity eviction act on actual input size
//  instead of the covered-edge count (which saturates once coverage does,
//  leaving term-size drift invisible to every pool mechanism).
//

import Testing
@testable import PropertyTestingKit

@Suite("Input size metric")
struct InputSizeTests {

    private final class EventLog: PoolPlugin {
        var events: [PoolEvent] = []
        func handle(event: PoolEvent) -> [PoolAction] {
            events.append(event)
            return []
        }
        var removed: [Int] {
            events.compactMap { if case let .removed(id) = $0 { return id } else { return nil } }
        }
    }

    private func accept(
        _ core: WeightedPoolCore,
        edges: [UInt32],
        features: [UInt64]? = nil,
        inputSize: Int? = nil
    ) -> Int? {
        core.observe(PoolIterationOutcome(
            source: .generated,
            newCoverage: SparseCoverage(indices: edges),
            features: features,
            inputSize: inputSize))
    }

    // MARK: - Mutator surface

    @Test("Mutator size closure defaults to nil")
    func mutatorSizeDefaultsToNil() {
        let mutator = Mutator<Int>(
            seeds: [1],
            mutate: { value, _ in value + 1 },
            generate: { _ in 0 })
        #expect(mutator.size == nil)
    }

    @Test("Mutator stores its size closure")
    func mutatorStoresSizeClosure() {
        let mutator = Mutator<String>(
            seeds: ["a"],
            mutate: { value, _ in value },
            generate: { _ in "a" },
            size: { $0.count })
        #expect(mutator.size?("hello") == 5)
    }

    @Test("Compose propagates a component's size closure")
    func composePropagatesSize() {
        let blind = Mutator<Int>(
            seeds: [1], mutate: { value, _ in value }, generate: { _ in 0 })
        let sighted = Mutator<Int>(
            seeds: [2], mutate: { value, _ in value }, generate: { _ in 0 },
            size: { $0 * 10 })
        #expect(Mutator.compose([blind, sighted]).size?(3) == 30)
        #expect(Mutator.compose([sighted, blind]).size?(3) == 30)
        #expect(Mutator.compose([blind, blind]).size == nil)
        #expect(blind.combined(with: sighted).size?(3) == 30)
    }

    // MARK: - REDUCE on real size

    @Test("REDUCE steals on real input size when coverage counts tie")
    func reduceStealsOnRealSize() {
        let core = WeightedPoolCore(
            admission: .featureOwnership, policies: [],
            burstLength: 1, focusOnInsert: false)
        // Equal coverage counts: under the edge-count proxy this is a tie and
        // ties never steal. Real size 10 < 50 must win the feature.
        #expect(accept(core, edges: [1, 2], features: [100], inputSize: 50) == 0)
        #expect(accept(core, edges: [3, 4], features: [100], inputSize: 10) == 1)
    }

    @Test("Without a size metric the edge-count proxy still rules (ties don't steal)")
    func edgeCountProxyFallback() {
        let core = WeightedPoolCore(
            admission: .featureOwnership, policies: [],
            burstLength: 1, focusOnInsert: false)
        #expect(accept(core, edges: [1, 2], features: [100]) == 0)
        #expect(accept(core, edges: [3, 4], features: [100]) == nil)
    }

    @Test("A larger real size never steals even with fewer covered edges")
    func largerRealSizeNeverSteals() {
        let core = WeightedPoolCore(
            admission: .featureOwnership, policies: [],
            burstLength: 1, focusOnInsert: false)
        #expect(accept(core, edges: [1, 2, 3], features: [100], inputSize: 10) == 0)
        #expect(accept(core, edges: [4], features: [100], inputSize: 50) == nil)
    }

    // MARK: - Capacity eviction on real size

    @Test("Capacity victim is the largest resident among weight ties")
    func capacityEvictsLargest() {
        let log = EventLog()
        let core = WeightedPoolCore(
            admission: .everyDiscovery, policies: [log],
            burstLength: 1, focusOnInsert: false, capacity: 2)
        // Entry 0 is the big one; entry 1 is small and NEWER. Under the
        // size-blind rule the tie-break (newest) would evict 1 — with real
        // sizes the monster goes.
        #expect(accept(core, edges: [1], inputSize: 50) == 0)
        #expect(accept(core, edges: [2], inputSize: 10) == 1)
        #expect(accept(core, edges: [3], inputSize: 20) == 2)
        #expect(log.removed == [0], "the largest resident yields, not the newest")
    }

    @Test("Capacity victim falls back to evict-newest when sizes are absent")
    func capacityVictimFallsBackToNewest() {
        let log = EventLog()
        let core = WeightedPoolCore(
            admission: .everyDiscovery, policies: [log],
            burstLength: 1, focusOnInsert: false, capacity: 2)
        #expect(accept(core, edges: [1]) == 0)
        #expect(accept(core, edges: [2]) == 1)
        #expect(accept(core, edges: [3]) == 2)
        #expect(log.removed == [1], "size-blind pools keep the elder-anchoring rule")
    }

    // MARK: - End to end

    @Test("The engine feeds mutator-measured sizes to the pool, summed across the pack")
    func engineFeedsSizesToPool() async throws {
        let sizes = SyncBox<[Int?]>([])
        let spy = SyncBox<Int>(0)

        let probe = FuzzPlugin<Int, Int>(id: "stop_probe", handleSync: { event in
            switch event {
            case .iteration:
                spy.update { $0 += 1 }
                if spy.value >= 300 {
                    return [.stop(.init(reason: .custom("observed_enough")))]
                }
                return []
            }
        })

        final class SizeTap: PoolPlugin {
            let sizes: SyncBox<[Int?]>
            init(sizes: SyncBox<[Int?]>) { self.sizes = sizes }
            func handle(event: PoolEvent) -> [PoolAction] {
                if case let .iteration(outcome) = event, outcome.newCoverage != nil {
                    sizes.update { $0.append(outcome.inputSize) }
                }
                return []
            }
        }

        let sized = Mutator<Int>(
            seeds: [1],
            mutate: { value, rng in value &+ Int(rng.next() % 7) },
            generate: { rng in Int(rng.next() % 1000) },
            size: { _ in 3 })
        let blind = Mutator<Int>(
            seeds: [2],
            mutate: { value, rng in value &- Int(rng.next() % 7) },
            generate: { rng in Int(rng.next() % 1000) })

        _ = try await fuzz(
            using: sized, blind,
            duration: .seconds(10),
            persistence: .ephemeral,
            scheduler: .weightedPool(policies: { [SizeTap(sizes: sizes)] }),
            parallelism: 1,
            plugins: { [probe] }
        ) { (a: Int, b: Int) in
            blackHole(a &+ b)
        }

        let accepted = sizes.value
        #expect(!accepted.isEmpty, "some inputs should be accepted")
        // Only the sized mutator contributes; the blind one is skipped.
        #expect(accepted.allSatisfy { $0 == 3 })
    }
}
