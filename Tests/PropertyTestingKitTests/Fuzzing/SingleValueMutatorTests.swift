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
@testable import FuzzCore

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

    @Test("Character default mutator explores beyond the 8 seed characters")
    func characterDefaultMutatorReachesBeyondSeeds() {
        var rng = FastRNG()
        let seeds: Set<Character> = ["a", "Z", "0", " ", "\n", "\t", "😄", "\0"]
        var seen = Set<Character>()
        var sawNeighbor = false
        for _ in 0..<800 {
            let mutant = Character.defaultMutator.mutate("a", &rng)
            #expect(mutant != "a")
            seen.insert(mutant)
            if mutant == "b" || mutant == "A" {
                sawNeighbor = true
            }
        }
        #expect(seen.count > seeds.count, "mutate should reach more than the 8 seed characters")
        #expect(sawNeighbor, "expected neighborhood exploration near 'a'")
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

    @Test("Double default mutator never returns the input for fixed-point-prone values")
    func doubleDefaultMutatorNeverIdentity() {
        var rng = FastRNG()
        // 0.0 (where `-value` and `value * 2` collapse to 0.0) and large
        // magnitudes (where ±1 / ±0.1 fall below the ULP and round back) are
        // the values a single-strategy pick can leave unchanged.
        let prone: [Double] = [0.0, -0.0, 1e300, -1e300, .greatestFiniteMagnitude]
        for value in prone {
            for _ in 0..<500 {
                #expect(Double.defaultMutator.mutate(value, &rng) != value,
                        "identity mutant produced for \(value)")
            }
        }
    }

    @Test("String default mutator never returns the input for multi-byte strings")
    func stringDefaultMutatorNeverIdentityMultibyte() {
        var rng = FastRNG()
        // utf8.count exceeds the Character count, so a byte-length-vs-`prefix`
        // mismatch in the length-targeted branch could slice back to the whole
        // string.
        let prone = ["é", "café", "🎉🎉🎉", "ñoño"]
        for value in prone {
            for _ in 0..<500 {
                #expect(String.defaultMutator.mutate(value, &rng) != value,
                        "identity mutant produced for \(value)")
            }
        }
    }

    // MARK: - Named mutators never produce identity mutants

    @Test("Port mutator never returns the input for well-known ports")
    func portMutatorNeverIdentity() {
        var rng = FastRNG()
        // `value % 65536` is the identity branch for any port in [0, 65536);
        // these are exactly the ports the seed list targets.
        let prone = [0, 80, 443, 8080, 65535]
        for value in prone {
            for _ in 0..<500 {
                #expect(Mutator<Int>.ports.mutate(value, &rng) != value,
                        "identity mutant produced for port \(value)")
            }
        }
    }

    @Test("HTTP status code mutator never returns the input for standard codes")
    func httpStatusCodeMutatorNeverIdentity() {
        var rng = FastRNG()
        // `value % 600` is the identity branch for any code in [0, 600).
        let prone = [200, 301, 404, 500, 0]
        for value in prone {
            for _ in 0..<500 {
                #expect(Mutator<Int>.httpStatusCodes.mutate(value, &rng) != value,
                        "identity mutant produced for status \(value)")
            }
        }
    }

    @Test("Percentage mutator never returns the input for boundary ratios")
    func percentageMutatorNeverIdentity() {
        var rng = FastRNG()
        // 0.0 (`value * 0.5` and `max(0, value - 0.1)` collapse), 0.5
        // (`1 - value`), and 1.0 (`min(1, value + 0.1)`) each pin one strategy.
        let prone: [Double] = [0.0, 0.5, 1.0]
        for value in prone {
            for _ in 0..<500 {
                #expect(Mutator<Double>.percentages.mutate(value, &rng) != value,
                        "identity mutant produced for percentage \(value)")
            }
        }
    }

    @Test("Empty string mutator never returns the input, including empty")
    func emptyStringMutatorNeverIdentity() {
        var rng = FastRNG()
        // A single character pins both `String(first)` and `String(last)` to the
        // input; the empty string pins the only other strategy (doubling "" is
        // "") and must escape to a non-empty whitespace seed.
        let prone = ["", "a", " ", "\t", "ab"]
        for value in prone {
            for _ in 0..<500 {
                #expect(emptyStringMutator.mutate(value, &rng) != value,
                        "identity mutant produced for \(value.debugDescription)")
            }
        }
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
                // Burst mutants carry the emitting plugin's originID (7).
                if ctx.parentID == 7 {
                    if firstQueueCount.value == nil {
                        firstQueueCount.update { $0 = ctx.queueCount }
                    }
                    mutantsSeen.update { $0 += 1 }
                    if mutantsSeen.value == FuzzEngineConfig().mutationBurstLength {
                        return [.stop(.init(reason: .custom("burst_complete")))]
                    }
                    return []
                }
                // Seed the burst from the first untagged input (parentID nil:
                // generated or scheduler-produced, not a bus mutant).
                if !tagged.value, ctx.parentID == nil {
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
        #expect(firstQueueCount.value == FuzzEngineConfig().mutationBurstLength - 1)
        #expect(mutantsSeen.value == FuzzEngineConfig().mutationBurstLength)
    }
}
