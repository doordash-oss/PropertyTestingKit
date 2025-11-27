//
//  NoInlineTest.swift
//  PropertyTestingKit
//

import Testing
import PropertyTestingKit

/// Test class with @inline(never) to prevent inlining.
class NoInlineTestClass {
    var value = 0

    @inline(never)
    func increment() {
        value += 1
    }

    @inline(never)
    func decrement() {
        value -= 1
    }
}

@Suite(.serialized)
struct NoInlineTests {
    @Test("@inline(never) methods should have coverage counters")
    func testNoInlineMethods() throws {
        let (result, coverage) = try measureSourceCoverage {
            let obj = NoInlineTestClass()
            obj.increment()
            obj.decrement()
            return obj.value
        }

        #expect(result == 0)

        // Check coverage for our test class
        let testClassFunctions = coverage.functions.filter { $0.name.contains("NoInlineTestClass") }
        print("\n=== NoInlineTestClass Functions ===")
        for fn in testClassFunctions {
            print("- \(fn.name): exec=\(fn.executionCount), regions=\(fn.regions.count)")
            for region in fn.regions {
                print("  \(region.lineStart):\(region.columnStart) = \(region.executionCount)")
            }
        }

        // Verify increment and decrement were captured
        let incrementFunc = testClassFunctions.first { $0.name.contains("increment") }
        let decrementFunc = testClassFunctions.first { $0.name.contains("decrement") }

        #expect(incrementFunc != nil, "Should have increment function in coverage")
        #expect(decrementFunc != nil, "Should have decrement function in coverage")

        if let incrementFunc {
            let hasExecuted = incrementFunc.regions.contains { $0.executionCount > 0 }
            #expect(hasExecuted, "increment() should have executed regions")
        }
    }
}
