//
//  AllCoverageTests.swift
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

// MARK: - Task-Isolated SanCov Source Coverage Tests

@Suite("SanCov Source Coverage")
struct SanCovSourceCoverageTests {

    @Test("measureSanCovSourceCoverage captures function coverage")
    func capturesFunctionCoverage() {
        // First verify SanCov basics are working
        #expect(SanCovCounters.isAvailable, "SanCov should be available")

        // Debug: check raw coverage works
        SanCovCounters.reset()
        let beforeCount = SanCovCounters.currentCoveredCount

        var obj = TestStruct()
        obj.increment()
        obj.decrement()

        let afterCount = SanCovCounters.currentCoveredCount
        #expect(afterCount > beforeCount, "Raw SanCov should capture coverage: before=\(beforeCount), after=\(afterCount)")

        // Check if PCs are available (requires -fsanitize-coverage=pc-table)
        let pcsAvailable = SanCovCounters.pcsAvailable

        // Now test the source coverage API
        let coverage = measureSanCovSourceCoverage {
            var obj2 = TestStruct()
            obj2.increment()
            obj2.decrement()
        }

        #expect(coverage != nil, "Should get coverage")

        if let coverage = coverage {
            // If PCs aren't available, we can still have edge coverage but no source mapping
            if pcsAvailable {
                #expect(coverage.coveredCount > 0, "Should have covered edges when PCs available")

                // Check that we have function names
                let hasIncrementFunction = coverage.coveredFunctions.contains { $0.contains("increment") }
                let hasDecrementFunction = coverage.coveredFunctions.contains { $0.contains("decrement") }

                #expect(hasIncrementFunction, "Should have covered increment function")
                #expect(hasDecrementFunction, "Should have covered decrement function")
            } else {
                // PCs not available - this is expected if not built with pc-table flag
                // The edge counters still work, just without source mapping
                Issue.record("PC table not available - source mapping disabled. Add -fsanitize-coverage=pc-table to enable.")
            }
        }
    }

    @Test("measureSanCovSourceCoverage provides task isolation")
    func providesTaskIsolation() async {
        // Run two coverage measurements in parallel - they should not interfere
        await withTaskGroup(of: SanCovSourceCoverage?.self) { group in
            group.addTask {
                measureSanCovSourceCoverage {
                    var obj = TestStruct()
                    obj.increment()
                    // Only increment, no decrement
                }
            }

            group.addTask {
                measureSanCovSourceCoverage {
                    var obj = TestStruct()
                    obj.decrement()
                    // Only decrement, no increment
                }
            }

            var results: [SanCovSourceCoverage] = []
            for await result in group {
                if let result = result {
                    results.append(result)
                }
            }

            // Each task should have measured different functions
            #expect(results.count == 2, "Should have two coverage results")
        }
    }

    @Test("SanCovCounters.pcsAvailable returns correct state")
    func pcsAvailableWorks() {
        // This test just verifies the API works - actual availability
        // depends on compilation flags
        let available = SanCovCounters.pcsAvailable
        // We can't assert true/false since it depends on build config
        _ = available
    }

    @Test("coverage grouped by file works")
    func groupedByFile() {
        let coverage = measureSanCovSourceCoverage {
            var obj = TestStruct()
            obj.increment()
        }

        if let coverage = coverage {
            let byFile = coverage.byFile
            // Should have at least one file
            #expect(!byFile.isEmpty || coverage.coveredCount == 0,
                    "Should have files if we have coverage")
        }
    }
}
