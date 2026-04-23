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
        Mutator(seeds: _seeds, mutate: { value in
            _seeds.filter { $0 != value }
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
        #expect(Bool.defaultMutator.mutate(true) == [false])
        #expect(Bool.defaultMutator.mutate(false) == [true])
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

    @Test("Int mutation produces nearby values")
    func testIntMutation() {
        let mutations = Int.defaultMutator.mutate(10)
        #expect(mutations.contains(11))  // +1
        #expect(mutations.contains(9))   // -1
        #expect(mutations.contains(-10)) // negate
        #expect(mutations.contains(5))   // /2
        #expect(mutations.contains(20))  // *2
    }

    @Test("String seeds include edge cases")
    func testStringSeeds() {
        let seeds = String.defaultMutator.seeds
        #expect(seeds.contains(""))           // Empty
        #expect(seeds.contains { $0.count == 1 })  // Single char
        #expect(seeds.contains { $0.count >= 100 }) // Long
    }

    @Test("String mutation produces variations")
    func testStringMutation() {
        let mutations = String.defaultMutator.mutate("hello")
        #expect(mutations.contains("hell"))    // Drop last
        #expect(mutations.contains("ello"))    // Drop first
        #expect(mutations.contains("hellox"))  // Append
        #expect(mutations.contains("HELLO"))   // Uppercase
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
        let mutations = Double.defaultMutator.mutate(10.0)
        #expect(mutations.contains(11.0))   // +1
        #expect(mutations.contains(9.0))    // -1
        #expect(mutations.contains(-10.0))  // negate
        #expect(mutations.contains(5.0))    // /2
        #expect(mutations.contains(20.0))   // *2
        #expect(mutations.contains(10.1))   // +0.1
        #expect(mutations.contains(9.9))    // -0.1
    }

    @Test("Double mutation handles zero")
    func testDoubleMutationZero() {
        let mutations = Double.defaultMutator.mutate(0.0)
        #expect(mutations.contains(1.0))    // +1
        #expect(mutations.contains(-1.0))   // -1
        #expect(mutations.contains(0.0))    // *2 (0*2=0)
        #expect(mutations.contains(0.1))    // +0.1
        #expect(mutations.contains(-0.1))   // -0.1
        // Should NOT contain /2 since value is 0
    }

    @Test("UInt seeds include boundary values")
    func testUIntSeeds() {
        let seeds = UInt.defaultMutator.seeds
        #expect(seeds.contains(0))
        #expect(seeds.contains(1))
        #expect(seeds.contains(UInt.max))
    }

    @Test("UInt mutation produces doubled value for small numbers")
    func testUIntMutationDouble() {
        // Test with a value that's small enough to double without overflow
        let mutations = UInt.defaultMutator.mutate(42)
        #expect(mutations.contains(43))   // +1
        #expect(mutations.contains(41))   // -1
        #expect(mutations.contains(21))   // /2
        #expect(mutations.contains(84))   // *2 (only for values <= UInt.max/2)
    }

    @Test("Custom MutatorProviding type")
    func testCustomMutatorProviding() {
        // TestDirection uses a custom MutatorProviding implementation
        let mutations = TestDirection.defaultMutator.mutate(.north)
        #expect(!mutations.contains(.north))  // Excludes current value
        #expect(mutations.contains(.south))
        #expect(mutations.contains(.east))
        #expect(mutations.contains(.west))
        #expect(mutations.count == 3)
    }
}
