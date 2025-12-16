//
//  FuzzableProtocolTests.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//
import Testing
import Foundation
import PropertyTestingKit

/// Test enum that uses the default mutate implementation
enum TestDirection: Fuzzable, Equatable {
    case north, south, east, west

    static var fuzz: [TestDirection] {
        [.north, .south, .east, .west]
    }
    // Note: No mutate implementation - uses default extension
}

@Suite("Fuzzable Protocol")
struct FuzzableProtocolTests {

    @Test("Bool fuzz values")
    func testBoolFuzz() {
        #expect(Bool.fuzz == [true, false])
    }

    @Test("Bool mutation flips value")
    func testBoolMutation() {
        #expect(true.mutate() == [false])
        #expect(false.mutate() == [true])
    }

    @Test("Int fuzz includes boundary values")
    func testIntFuzz() {
        let fuzz = Int.fuzz
        #expect(fuzz.contains(0))
        #expect(fuzz.contains(1))
        #expect(fuzz.contains(-1))
        #expect(fuzz.contains(Int.max))
        #expect(fuzz.contains(Int.min))
    }

    @Test("Int mutation produces nearby values")
    func testIntMutation() {
        let mutations = 10.mutate()
        #expect(mutations.contains(11))  // +1
        #expect(mutations.contains(9))   // -1
        #expect(mutations.contains(-10)) // negate
        #expect(mutations.contains(5))   // /2
        #expect(mutations.contains(20))  // *2
    }

    @Test("String fuzz includes edge cases")
    func testStringFuzz() {
        let fuzz = String.fuzz
        #expect(fuzz.contains(""))           // Empty
        #expect(fuzz.contains { $0.count == 1 })  // Single char
        #expect(fuzz.contains { $0.count >= 100 }) // Long
    }

    @Test("String mutation produces variations")
    func testStringMutation() {
        let mutations = "hello".mutate()
        #expect(mutations.contains("hell"))    // Drop last
        #expect(mutations.contains("ello"))    // Drop first
        #expect(mutations.contains("hellox"))  // Append
        #expect(mutations.contains("HELLO"))   // Uppercase
    }

    @Test("Optional fuzz includes nil")
    func testOptionalFuzz() {
        let fuzz: [Int?] = Optional<Int>.fuzz
        #expect(fuzz.contains(nil))
        #expect(fuzz.contains(0))
        #expect(fuzz.contains(1))
    }

    @Test("Array fuzz includes empty and non-empty")
    func testArrayFuzz() {
        let fuzz: [[Int]] = Array<Int>.fuzz
        #expect(fuzz.contains([]))
        #expect(fuzz.contains { !$0.isEmpty })
    }

    @Test("Double fuzz includes boundary values")
    func testDoubleFuzz() {
        let fuzz = Double.fuzz
        #expect(fuzz.contains(0.0))
        #expect(fuzz.contains(1.0))
        #expect(fuzz.contains(-1.0))
        #expect(fuzz.contains(Double.greatestFiniteMagnitude))
        #expect(fuzz.contains(Double.infinity))
        #expect(fuzz.contains { $0.isNaN })
    }

    @Test("Double mutation handles finite values")
    func testDoubleMutationFinite() {
        let mutations = 10.0.mutate()
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
        let mutations = 0.0.mutate()
        #expect(mutations.contains(1.0))    // +1
        #expect(mutations.contains(-1.0))   // -1
        #expect(mutations.contains(0.0))    // *2 (0*2=0)
        #expect(mutations.contains(0.1))    // +0.1
        #expect(mutations.contains(-0.1))   // -0.1
        // Should NOT contain /2 since value is 0
    }

    @Test("UInt fuzz includes boundary values")
    func testUIntFuzz() {
        let fuzz = UInt.fuzz
        #expect(fuzz.contains(0))
        #expect(fuzz.contains(1))
        #expect(fuzz.contains(UInt.max))
    }

    @Test("UInt mutation produces doubled value for small numbers")
    func testUIntMutationDouble() {
        // Test with a value that's small enough to double without overflow
        let mutations = (42 as UInt).mutate()
        #expect(mutations.contains(43))   // +1
        #expect(mutations.contains(41))   // -1
        #expect(mutations.contains(21))   // /2
        #expect(mutations.contains(84))   // *2 (only for values <= UInt.max/2)
    }

    @Test("Default mutate for Equatable types")
    func testDefaultMutateForEquatable() {
        // TestDirection uses the default mutate implementation (no custom mutate)
        let mutations = TestDirection.north.mutate()
        #expect(!mutations.contains(.north))  // Excludes current value
        #expect(mutations.contains(.south))
        #expect(mutations.contains(.east))
        #expect(mutations.contains(.west))
        #expect(mutations.count == 3)
    }
}
