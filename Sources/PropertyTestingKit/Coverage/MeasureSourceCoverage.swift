//
//  MeasureSourceCoverage.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Foundation

/// Measure coverage with source location mapping (context-isolated).
///
/// This combines context-isolated SanCov coverage with source location mapping.
/// Coverage is isolated to a unique measurement context, allowing parallel test execution
/// without contamination - even for synchronous tests.
///
/// ```swift
/// let coverage = measureSanCovSourceCoverage {
///     myFunction()
/// }
/// for file in coverage?.coveredFiles ?? [] {
///     print("Covered: \(file)")
/// }
/// ```
///
/// - Parameter body: The code to measure.
/// - Returns: Source-mapped coverage, or nil if SanCov unavailable.
@discardableResult
public func measureSanCovSourceCoverage(_ body: () throws -> Void) async rethrows -> SanCovSourceCoverage? {
    guard SanCovCounters.isAvailable else { return nil }
    guard let context = SanCovCounters.beginMeasurement() else { return nil }
    defer { SanCovCounters.endMeasurement(context) }

    // Reset context-isolated counters
    SanCovCounters.reset()

    // Run the code
    try body()

    // Get source-mapped coverage
    let locations = await SanCovCounters.getCoveredLocations()
    return SanCovSourceCoverage(coveredLocations: locations)
}

/// Measure coverage with source location mapping (context-isolated, async body).
@discardableResult
public func measureSanCovSourceCoverage(_ body: () async throws -> Void) async rethrows -> SanCovSourceCoverage? {
    guard SanCovCounters.isAvailable else { return nil }
    guard let context = SanCovCounters.beginMeasurement() else { return nil }
    defer { SanCovCounters.endMeasurement(context) }

    // Reset context-isolated counters
    SanCovCounters.reset()

    // Run the code
    try await body()

    // Get source-mapped coverage
    let locations = await SanCovCounters.getCoveredLocations()
    return SanCovSourceCoverage(coveredLocations: locations)
}
