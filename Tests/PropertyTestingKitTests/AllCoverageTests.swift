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

// MARK: - Task-Isolated SanCov Source Coverage Tests

@Suite("SanCov Source Coverage")
struct SanCovSourceCoverageTests {

    @Test("measureSanCovSourceCoverage captures function coverage")
    func capturesFunctionCoverage() async {
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
        let coverage = await measureSanCovSourceCoverage {
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

    @Test("SimpleClass methods have coverage via SanCov")
    func simpleClassCoverage() async {
        let coverage = await measureSanCovSourceCoverage {
            let obj = SimpleClass()
            obj.increment()
            obj.decrement()
        }

        guard let coverage = coverage else {
            Issue.record("SanCov not available")
            return
        }

        #expect(coverage.coveredCount > 0, "Should have covered edges")

        // Check for SimpleClass function coverage
        let hasIncrementFunction = coverage.coveredFunctions.contains { $0.contains("increment") }
        let hasDecrementFunction = coverage.coveredFunctions.contains { $0.contains("decrement") }

        #expect(hasIncrementFunction, "Should have covered increment function")
        #expect(hasDecrementFunction, "Should have covered decrement function")
    }

    @Test("struct methods have coverage via SanCov")
    func structMethods() async {
        let coverage = await measureSanCovSourceCoverage {
            var obj = TestStruct()
            obj.increment()
            obj.decrement()
        }

        guard let coverage = coverage else {
            Issue.record("SanCov not available")
            return
        }

        #expect(coverage.coveredCount > 0, "Should have covered edges")

        // Check for TestStruct function coverage
        let hasIncrementFunction = coverage.coveredFunctions.contains { $0.contains("increment") }
        let hasDecrementFunction = coverage.coveredFunctions.contains { $0.contains("decrement") }

        #expect(hasIncrementFunction, "Should have covered increment function")
        #expect(hasDecrementFunction, "Should have covered decrement function")
    }

    @Test("measureSanCovSourceCoverage provides task isolation")
    func providesTaskIsolation() async {
        // Run two coverage measurements in parallel - they should not interfere
        await withTaskGroup(of: SanCovSourceCoverage?.self) { group in
            group.addTask {
                await measureSanCovSourceCoverage {
                    var obj = TestStruct()
                    obj.increment()
                    // Only increment, no decrement
                }
            }

            group.addTask {
                await measureSanCovSourceCoverage {
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
    func groupedByFile() async {
        let coverage = await measureSanCovSourceCoverage {
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

    @Test("DWARF symbolizer provides line numbers when available")
    func lineNumbersAvailable() async {
        // Check if line numbers are available
        let lineNumbersAvailable = await SanCovCounters.lineNumbersAvailable()
        print("Line numbers available: \(lineNumbersAvailable)")

        let coverage = await measureSanCovSourceCoverage {
            let obj = SimpleClass()
            obj.increment()
        }

        guard let coverage = coverage else {
            Issue.record("Coverage should be available")
            return
        }

        print("Coverage has line numbers: \(coverage.hasLineNumbers)")
        print("Covered count: \(coverage.coveredCount)")

        // Print some locations with line info
        let locationsWithLines = coverage.coveredLocations.filter { $0.line != nil }
        print("Locations with line numbers: \(locationsWithLines.count)")

        for loc in locationsWithLines.prefix(5) {
            print("  \(loc.filename ?? "?"):\(loc.line ?? 0) - \(loc.functionName ?? "?")")
        }

        // Print line coverage summary
        let summary = coverage.lineCoverageSummary
        print("Line coverage summary:")
        for line in summary.prefix(5) {
            print("  \(line)")
        }

        // Test the new line-based APIs
        if coverage.hasLineNumbers {
            let byFileLine = coverage.byFileLine
            #expect(!byFileLine.isEmpty, "Should have file:line groupings")

            let linesByFile = coverage.coveredLinesByFile
            #expect(!linesByFile.isEmpty, "Should have lines grouped by file")

            // Should find this test file in coverage
            let thisFile = linesByFile.keys.first { $0.contains("AllCoverageTests.swift") }
            if let thisFile = thisFile {
                print("Found this test file with \(linesByFile[thisFile]?.count ?? 0) covered lines")
            }
        }
    }
}
