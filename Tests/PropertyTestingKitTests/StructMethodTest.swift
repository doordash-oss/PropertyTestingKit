//
//  StructMethodTest.swift
//  PropertyTestingKit
//

import Testing
import PropertyTestingKit

/// Test struct with methods.
struct TestStruct {
    var value = 0

    mutating func increment() {
        value += 1
    }

    func getValue() -> Int {
        return value
    }
}

@Suite(.serialized)
struct StructMethodTests {
    @Test("struct methods should have coverage counters")
    func testStructMethods() throws {
        let reader = try InMemoryCoverageReader.loadFromCurrentProcess()

        // Reset counters first
        CoverageCounters.reset()

        // Check before
        let coverageBefore = reader.resolveCoverage()
        let incrementBefore = coverageBefore.functions.first { $0.name.contains("TestStruct") && $0.name.contains("increment") }
        print("TestStruct.increment() counter BEFORE: \(incrementBefore?.executionCount ?? 999)")

        // Call methods multiple times - WITHOUT getValue to test counter assignment
        var obj = TestStruct()
        obj.increment()
        obj.increment()
        obj.increment()
        // No getValue calls - see if valueInit counter changes

        // Check after
        let coverageAfter = reader.resolveCoverage()
        let incrementAfter = coverageAfter.functions.first { $0.name.contains("TestStruct") && $0.name.contains("increment") }
        print("TestStruct.increment() counter AFTER: \(incrementAfter?.executionCount ?? 999)")
        print("TestStruct.value = \(obj.value)")

        // Check all struct functions
        let structFuncs = coverageAfter.functions.filter { $0.name.contains("TestStruct") }
        print("\n=== TestStruct Functions ===")
        for fn in structFuncs {
            print("- \(fn.name): exec=\(fn.executionCount)")
        }

        #expect(incrementAfter?.executionCount ?? 0 > 0, "increment() should have executed")
    }
}
