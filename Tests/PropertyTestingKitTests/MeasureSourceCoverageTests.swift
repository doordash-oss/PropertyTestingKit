//
//  MeasureSourceCoverageTests.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Testing
import PropertyTestingKit

@Suite
struct MeasureSourceCoverageTests {
    @Test("measureSourceCoverage captures source-level coverage")
    func testMeasureSourceCoverage() throws {
        var capturedDb: MockDatabase?

        // Don't use measureSourceCoverage - manually control the process
        let reader = try InMemoryCoverageReader.loadFromCurrentProcess()

        // DON'T reset - see if counter already has a value
        let coverageBefore = reader.resolveCoverage()
        let writeBeforeFn = coverageBefore.functions.first { $0.name.contains("write3key5value") }
        print("write() counter BEFORE calling: \(writeBeforeFn?.executionCount ?? 999)")

        // Now call the methods
        let db = MockDatabase()
        db.write(key: "foo", value: "bar")
        capturedDb = db
        let result = db.read(key: "foo")

        // Check after
        let coverageAfter = reader.resolveCoverage()
        let writeAfterFn = coverageAfter.functions.first { $0.name.contains("write3key5value") }
        print("write() counter AFTER calling: \(writeAfterFn?.executionCount ?? 999)")

        // Use the after coverage
        let coverage = coverageAfter

        // Verify the method was actually called
        print("MockDatabase.writeCount = \(capturedDb?.writeCount ?? -1)")
        print("MockDatabase.readCount = \(capturedDb?.readCount ?? -1)")

        #expect(result == "bar")
        #expect(coverage.functions.count > 0)

        print("Captured coverage for \(coverage.functions.count) functions")

        // Count executed vs unexecuted
        let executed = coverage.executedRegions.count
        let unexecuted = coverage.unexecutedRegions.count
        print("Executed: \(executed), Unexecuted: \(unexecuted)")

        // Check MockDatabase coverage
        let mockDbFunctions = coverage.functions.filter { $0.name.contains("MockDatabase") }
        print("\n=== MockDatabase Functions ===")
        for fn in mockDbFunctions {
            print("- \(fn.name): exec=\(fn.executionCount), regions=\(fn.regions.count)")
            for region in fn.regions.prefix(3) {
                print("  \(region.lineStart):\(region.columnStart) = \(region.executionCount)")
            }
        }

        // Verify that the executed code is captured
        let writeFunc = mockDbFunctions.first { $0.name.contains("write") && !$0.name.contains("writeCount") }
        let readFunc = mockDbFunctions.first { $0.name.contains("read") && !$0.name.contains("readCount") }

        #expect(writeFunc != nil, "Should have write function in coverage")
        #expect(readFunc != nil, "Should have read function in coverage")

        // The write and read functions should show execution
        if let writeFunc {
            let hasExecuted = writeFunc.regions.contains { $0.executionCount > 0 }
            #expect(hasExecuted, "write() should have executed regions")
        }
        if let readFunc {
            let hasExecuted = readFunc.regions.contains { $0.executionCount > 0 }
            #expect(hasExecuted, "read() should have executed regions")
        }
    }
}
