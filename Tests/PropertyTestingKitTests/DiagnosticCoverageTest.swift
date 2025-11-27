//
//  DiagnosticCoverageTest.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Testing
import PropertyTestingKit
import Foundation

@Suite(.serialized)
struct DiagnosticCoverageTest {
    @Test("Diagnose coverage hash matching")
    func testDiagnoseCoverageMatching() throws {
        let reader = try InMemoryCoverageReader.loadFromCurrentProcess()

        print("\n=== Coverage Mapping Info ===")
        print("Function count: \(reader.functionCount)")
        print("Source files: \(reader.sourceFiles.count)")

        // Get coverage (this will use function hash matching)
        let coverage = reader.resolveCoverage()

        print("\n=== Resolved Coverage ===")
        print("Functions with regions: \(coverage.functions.count)")
        print("Executed regions: \(coverage.executedRegions.count)")
        print("Unexecuted regions: \(coverage.unexecutedRegions.count)")

        // Print first few functions from coverage mapping
        print("\n=== Sample Functions ===")
        for (i, func_) in coverage.functions.prefix(5).enumerated() {
            print("\(i+1). \(func_.name) - hash: \(func_.hash), exec: \(func_.executionCount), regions: \(func_.regions.count)")
        }

        // Check if MockDatabase functions are in the coverage
        let mockDbFuncs = coverage.functions.filter { $0.name.contains("MockDatabase") }
        print("\n=== MockDatabase Functions ===")
        for func_ in mockDbFuncs {
            print("- \(func_.name): \(func_.executionCount) executions, \(func_.regions.count) regions")
            for region in func_.regions.prefix(3) {
                print("  Region \(region.lineStart):\(region.columnStart)-\(region.lineEnd):\(region.columnEnd) = \(region.executionCount)")
            }
        }
    }
}
