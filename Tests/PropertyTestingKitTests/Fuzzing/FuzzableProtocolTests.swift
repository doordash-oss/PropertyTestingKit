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

import Testing
import Foundation
import PropertyTestingKit

/// Test enum that uses MutatorProviding
enum TestDirection: MutatorProviding, Equatable, Sendable {
    case north, south, east, west

    private static let _seeds: [TestDirection] = [.north, .south, .east, .west]

    static var defaultMutator: Mutator<TestDirection> {
        Mutator(seeds: _seeds, mutate: { value, rng in
            let others = _seeds.filter { $0 != value }
            return others[Int.random(in: 0..<others.count, using: &rng)]
        })
    }
}

@Suite("MutatorProviding Protocol")
struct MutatorProvidingTests {

    @Test("Bool seeds")
    func testBoolSeeds() {
        #expect(Bool.defaultMutator.seeds == [true, false])
    }

    @Test("Bool mutation flips value")
    func testBoolMutation() {
        var rng = FastRNG()
        #expect(Bool.defaultMutator.mutate(true, &rng) == false)
        #expect(Bool.defaultMutator.mutate(false, &rng) == true)
    }

    @Test("Int seeds include boundary values")
    func testIntSeeds() {
        let seeds = Int.defaultMutator.seeds
        #expect(seeds.contains(0))
        #expect(seeds.contains(1))
        #expect(seeds.contains(-1))
        #expect(seeds.contains(Int.max))
        #expect(seeds.contains(Int.min))
    }

    @Test("Int mutation draws nearby values")
    func testIntMutation() {
        var rng = FastRNG()
        var seen = Set<Int>()
        for _ in 0..<200 { seen.insert(Int.defaultMutator.mutate(10, &rng)) }

        #expect(seen.contains(11))  // +1
        #expect(seen.contains(9))   // -1
        #expect(seen.contains(-10)) // negate
        #expect(seen.contains(5))   // /2
        #expect(seen.contains(20))  // *2
    }

    @Test("String seeds include edge cases")
    func testStringSeeds() {
        let seeds = String.defaultMutator.seeds
        #expect(seeds.contains(""))           // Empty
        #expect(seeds.contains { $0.count == 1 })  // Single char
        #expect(seeds.contains { $0.count >= 100 }) // Long
    }

    @Test("String mutation draws variations")
    func testStringMutation() {
        var rng = FastRNG()
        var seen = Set<String>()
        for _ in 0..<200 { seen.insert(String.defaultMutator.mutate("hello", &rng)) }

        #expect(seen.contains("hell"))    // Drop last
        #expect(seen.contains("ello"))    // Drop first
        #expect(seen.contains("hellox"))  // Append
        #expect(seen.contains("HELLO"))   // Uppercase
    }

    @Test("Optional seeds include nil")
    func testOptionalSeeds() {
        let seeds: [Int?] = Optional<Int>.defaultMutator.seeds
        #expect(seeds.contains(nil))
        #expect(seeds.contains(0))
        #expect(seeds.contains(1))
    }

    @Test("Array seeds include empty and non-empty")
    func testArraySeeds() {
        let seeds: [[Int]] = Array<Int>.defaultMutator.seeds
        #expect(seeds.contains([]))
        #expect(seeds.contains { !$0.isEmpty })
    }

    @Test("Double seeds include boundary values")
    func testDoubleSeeds() {
        let seeds = Double.defaultMutator.seeds
        #expect(seeds.contains(0.0))
        #expect(seeds.contains(1.0))
        #expect(seeds.contains(-1.0))
        #expect(seeds.contains(Double.greatestFiniteMagnitude))
        #expect(seeds.contains(Double.infinity))
        #expect(seeds.contains { $0.isNaN })
    }

    @Test("Double mutation handles finite values")
    func testDoubleMutationFinite() {
        var rng = FastRNG()
        var seen = Set<Double>()
        for _ in 0..<200 { seen.insert(Double.defaultMutator.mutate(10.0, &rng)) }

        #expect(seen.contains(11.0))   // +1
        #expect(seen.contains(9.0))    // -1
        #expect(seen.contains(-10.0))  // negate
        #expect(seen.contains(5.0))    // /2
        #expect(seen.contains(20.0))   // *2
        #expect(seen.contains(10.1))   // +0.1
        #expect(seen.contains(9.9))    // -0.1
    }

    @Test("Double mutation handles zero")
    func testDoubleMutationZero() {
        var rng = FastRNG()
        var seen = Set<Double>()
        for _ in 0..<200 { seen.insert(Double.defaultMutator.mutate(0.0, &rng)) }

        #expect(seen.contains(1.0))    // +1
        #expect(seen.contains(-1.0))   // -1
        #expect(seen.contains(0.0))    // *2 (0*2=0)
        #expect(seen.contains(0.1))    // +0.1
        #expect(seen.contains(-0.1))   // -0.1
        // Should NOT contain /2 since value is 0
    }

    @Test("UInt seeds include boundary values")
    func testUIntSeeds() {
        let seeds = UInt.defaultMutator.seeds
        #expect(seeds.contains(0))
        #expect(seeds.contains(1))
        #expect(seeds.contains(UInt.max))
    }

    @Test("UInt mutation draws doubled value for small numbers")
    func testUIntMutationDouble() {
        // Test with a value that's small enough to double without overflow
        var rng = FastRNG()
        var seen = Set<UInt>()
        for _ in 0..<200 { seen.insert(UInt.defaultMutator.mutate(42, &rng)) }

        #expect(seen.contains(43))   // +1
        #expect(seen.contains(41))   // -1
        #expect(seen.contains(21))   // /2
        #expect(seen.contains(84))   // *2 (only for values <= UInt.max/2)
    }

    @Test("Custom MutatorProviding type")
    func testCustomMutatorProviding() {
        // TestDirection uses a custom MutatorProviding implementation
        var rng = FastRNG()
        var seen = Set<TestDirection>()
        for _ in 0..<200 { seen.insert(TestDirection.defaultMutator.mutate(.north, &rng)) }

        // Draws every other direction, never the current value
        #expect(seen == Set([.south, .east, .west]))
    }
}
