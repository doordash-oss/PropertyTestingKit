//
//  File.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Testing
import PropertyTestingKit

// MARK: - Diagnostic Tests

@Suite("Coverage Diagnostics")
struct CoverageDiagnostics {
    @Test("Check coverage availability")
    func testCoverageAvailability() {
        print("Coverage instrumentation available: \(PerTestCoverage.isAvailable)")
    }
}
