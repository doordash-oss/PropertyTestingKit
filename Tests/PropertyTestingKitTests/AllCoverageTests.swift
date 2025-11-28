//
//  AllCoverageTests.swift
//  PropertyTestingKit
//
//  Parent suite that serializes all coverage-dependent tests.
//  This prevents parallel execution issues with global counter state.
//

import Testing
import PropertyTestingKit

/// Test struct with methods.
struct TestStruct {
    var value = 0

    mutating func increment() {
        value += 1
    }

    mutating func decrement() {
        value -= 1
    }
}

/// Simple class to test coverage
class SimpleClass {
    var value = 0

    @inline(never)
    func increment() {
        let oldValue = value
        value = oldValue + 1
        _ = oldValue
    }

    @inline(never)
    func decrement() {
        let oldValue = value
        value = oldValue - 1
        _ = oldValue
    }
}

// MARK: - Serialized Test Suite

/// All tests that depend on coverage counter state must be in this serialized suite
/// to prevent parallel execution issues.
@Suite("Coverage Counter Tests", .serialized)
struct AllCoverageTests {

    @Test("SimpleClass methods have coverage counters")
    func simpleClassCoverage() throws {
        let (result, coverage) = try measureSourceCoverage {
            let obj = SimpleClass()
            obj.increment()
            obj.decrement()
            return obj.value
        }

        #expect(result == 0)

        let simpleClassFns = coverage.functions.filter { $0.name.contains("SimpleClass") }
        let incrementFn = simpleClassFns.first { $0.name.contains("increment") }
        let decrementFn = simpleClassFns.first { $0.name.contains("decrement") }

        #expect(incrementFn != nil, "Should have increment function")
        #expect(decrementFn != nil, "Should have decrement function")

        if let inc = incrementFn {
            #expect(inc.executionCount == 1, "increment should have been executed")
        }
    }

    @Test("struct methods have coverage counters")
    func structMethods() throws {
        let (result, coverage) = try measureSourceCoverage {
            var obj = TestStruct()
            obj.increment()
            obj.decrement()
            return obj.value
        }

        #expect(result == 0)

        let testStructFunctions = coverage.functions.filter { $0.name.contains("TestStruct") }
        let incrementFunc = testStructFunctions.first { $0.name.contains("increment") }
        let decrementFunc = testStructFunctions.first { $0.name.contains("decrement") }

        #expect(incrementFunc != nil, "Should have increment function in coverage")

        if let incrementFunc {
            #expect(incrementFunc.executionCount == 1, "increment() should have been executed")
        }

        if let decrementFunc {
            #expect(decrementFunc.executionCount == 1, "decrement() should have been executed")
        }
    }

    @Test
    func structMethodsMeasuresMultipleCalls() throws {
        let (result, coverage) = try measureSourceCoverage {
            var obj = TestStruct()
            obj.increment()
            obj.increment()
            obj.increment()
            return obj.value
        }

        #expect(result == 3)

        let testStructFunctions = coverage.functions.filter { $0.name.contains("TestStruct") }
        let incrementFunc = testStructFunctions.first { $0.name.contains("increment") }
        let decrementFunc = testStructFunctions.first { $0.name.contains("decrement") }

        #expect(incrementFunc != nil, "Should have increment function in coverage")

        if let incrementFunc {
            #expect(incrementFunc.executionCount == 3, "increment() should have been executed")
        }

        if let decrementFunc {
            #expect(decrementFunc.executionCount == 0, "decrement() should have been executed")
        }
    }

    @Test
    func structMethodsDoNotMeasureExternalCalls() throws {
        var obj = TestStruct()
        let (result, coverage) = try measureSourceCoverage {
            obj.increment()
            obj.increment()
            obj.increment()
            return obj.value
        }

        obj.increment()

        #expect(result == 3)
        #expect(obj.value == 4)

        let testStructFunctions = coverage.functions.filter { $0.name.contains("TestStruct") }
        let incrementFunc = testStructFunctions.first { $0.name.contains("increment") }
        let decrementFunc = testStructFunctions.first { $0.name.contains("decrement") }

        #expect(incrementFunc != nil, "Should have increment function in coverage")

        if let incrementFunc {
            #expect(incrementFunc.executionCount == 3, "increment() should have been executed")
        }

        if let decrementFunc {
            #expect(decrementFunc.executionCount == 0, "decrement() should have been executed")
        }
    }
}
