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

//  Single-value mutators (issue #41): `mutate` produces ONE mutant per call,
//  drawing variety from the supplied RNG. Effort (how many mutants, how many
//  stacked steps) belongs to the caller, not the mutator.
//
//  FastRNG is a stateless shim over thread-local state and cannot be seeded,
//  so these tests assert membership/coverage contracts over many draws rather
//  than seeded determinism.
//

import Testing
@testable import PropertyTestingKit

@Suite("Single-value mutators")
struct SingleValueMutatorTests {

    // MARK: - API shape

    @Test("Custom mutator produces one mutant per call")
    func customMutatorSingleValue() {
        let mutator = Mutator<Int>(
            seeds: [0],
            mutate: { value, _ in value + 1 },
            generate: { _ in 0 }
        )
        var rng = FastRNG()
        #expect(mutator.mutate(5, &rng) == 6)
    }

    // MARK: - Built-in conformances

    @Test("Int default mutator returns a changed value and varies across draws")
    func intDefaultMutatorVaries() {
        var rng = FastRNG()
        var seen = Set<Int>()
        for _ in 0..<200 {
            let mutant = Int.defaultMutator.mutate(100, &rng)
            #expect(mutant != 100)
            seen.insert(mutant)
        }
        // The old enumeration had ~15 variants for 100; a single-value picker
        // must still reach several of them across draws.
        #expect(seen.count >= 4)
    }

    @Test("String default mutator returns a changed value and varies across draws")
    func stringDefaultMutatorVaries() {
        var rng = FastRNG()
        var seen = Set<String>()
        for _ in 0..<200 {
            seen.insert(String.defaultMutator.mutate("hello", &rng))
        }
        #expect(seen.count >= 2)
    }

    // MARK: - Composition

    @Test("Composed mutator draws from every component and nothing else")
    func composeDrawsFromAllComponents() {
        let plusOne = Mutator<Int>(seeds: [0], mutate: { v, _ in v + 1 }, generate: { _ in 0 })
        let minusOne = Mutator<Int>(seeds: [0], mutate: { v, _ in v - 1 }, generate: { _ in 0 })
        let composed = Mutator.compose([plusOne, minusOne])

        var rng = FastRNG()
        var seen = Set<Int>()
        for _ in 0..<100 {
            seen.insert(composed.mutate(0, &rng))
        }
        #expect(seen == [1, -1])
    }

    // MARK: - Schedule bytes

    @Test("Schedule byte mutator preserves length and changes content")
    func scheduleByteMutatorSingleValue() {
        var rng = FastRNG()
        let bytes: [UInt8] = Array(0..<64)
        var changed = 0
        for _ in 0..<50 {
            let mutant = ScheduleByteMutator.mutate(bytes, using: &rng)
            #expect(mutant.count == bytes.count)
            if mutant != bytes { changed += 1 }
        }
        // An even number of flips on the same bit can no-op; anything beyond
        // a rare collision must differ.
        #expect(changed >= 45)
    }

    // MARK: - Engine: one position per mutant

    @Test("mutateOnePosition changes exactly the chosen position")
    func mutateOnePositionChangesChosenPosition() {
        let intMutator = Mutator<Int>(seeds: [0], mutate: { v, _ in v + 1 }, generate: { _ in 0 })
        let stringMutator = Mutator<String>(seeds: [""], mutate: { s, _ in s + "x" }, generate: { _ in "" })
        var rng = FastRNG()

        let (i0, s0) = mutateOnePosition((5, "ab"), position: 0, rng: &rng, mutators: intMutator, stringMutator)
        #expect(i0 == 6)
        #expect(s0 == "ab")

        let (i1, s1) = mutateOnePosition((5, "ab"), position: 1, rng: &rng, mutators: intMutator, stringMutator)
        #expect(i1 == 5)
        #expect(s1 == "abx")
    }

    // MARK: - Engine: fixed burst per selection

    @Test("selectForMutation queues a fixed burst of single-step mutants")
    func selectForMutationQueuesFixedBurst() async throws {
        let firstQueueCount = SyncBox<Int?>(nil)
        let mutantsSeen = SyncBox<Int>(0)
        let tagged = SyncBox<Bool>(false)

        let probe = FuzzPlugin<Int>(id: "burst_probe", handleSync: { event in
            switch event {
            case let .iteration(ctx):
                if ctx.fromMutationQueue, ctx.parentID == 7 {
                    if firstQueueCount.value == nil {
                        firstQueueCount.update { $0 = ctx.queueCount }
                    }
                    mutantsSeen.update { $0 += 1 }
                    if mutantsSeen.value == mutationBurstLength {
                        return [.stop(.init(reason: .custom("burst_complete")))]
                    }
                    return []
                }
                if !tagged.value, !ctx.fromMutationQueue {
                    tagged.update { $0 = true }
                    return [.selectForMutation(.init(input: ctx.input, originID: 7))]
                }
                return []
            }
        })

        _ = try await fuzz(
            duration: .seconds(10),
            persistence: .ephemeral,
            parallelism: 1,
            plugins: { [probe] }
        ) { (input: Int) in
            blackHole(input)
        }

        // The first popped mutant sees the rest of its own burst queued.
        #expect(firstQueueCount.value == mutationBurstLength - 1)
        #expect(mutantsSeen.value == mutationBurstLength)
    }
}
