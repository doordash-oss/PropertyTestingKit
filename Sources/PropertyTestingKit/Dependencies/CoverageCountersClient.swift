//
//  CoverageCountersClient.swift
//  PropertyTestingKit
//
//  Dependency client for task-isolated coverage counters.
//

import Dependencies
import IssueReporting

/// Dependency client for coverage counter operations.
///
/// Uses SanitizerCoverage with task-keyed maps for true per-task isolation.
/// This enables parallel fuzzing without coverage contamination.
///
/// ## Build Requirements
///
/// Your test target must be compiled with sanitizer coverage flags:
/// ```swift
/// .testTarget(
///     name: "MyTests",
///     swiftSettings: [
///         .unsafeFlags(["-sanitize-coverage=edge,pc-table"])
///     ]
/// )
/// ```
public struct CoverageCountersClient: Sendable {
    /// Get a snapshot of current coverage counters for this task.
    public var snapshot: @Sendable () -> SanCovCounters?

    /// Get only the covered (non-zero) edges as parallel arrays.
    /// This is the fastest way to get sparse coverage data.
    /// Note: This is synchronous since the underlying SanCov implementation uses task-local data.
    public var snapshotCoveredArrays: @Sendable () -> SparseCoverage?

    /// Check if coverage instrumentation is available.
    public var isAvailable: @Sendable () -> Bool

    /// Begin a measurement context for the current task.
    /// This creates an isolated coverage map and pre-warms caches for optimal performance.
    /// Must be paired with endMeasurement.
    public var beginMeasurement: @Sendable () -> SanCovCounters.MeasurementContext

    /// End a measurement context and clean up resources.
    /// This frees the coverage map slot for reuse by other tasks.
    public var endMeasurement: @Sendable (SanCovCounters.MeasurementContext) -> Void

    /// Get covered indices using a specific measurement context.
    /// This bypasses TLS lookup, providing O(1) performance even after task hops.
    public var snapshotCoveredArraysWithContext: @Sendable (SanCovCounters.MeasurementContext) -> SparseCoverage?

    public init(
        snapshot: @escaping @Sendable () -> SanCovCounters? = unimplemented(
            "snapshot",
            placeholder: nil
        ),
        snapshotCoveredArrays: @escaping @Sendable () -> SparseCoverage? = unimplemented(
            "snapshotCoveredArrays",
            placeholder: nil
        ),
        isAvailable: @escaping @Sendable () -> Bool = unimplemented(
            "isAvailable",
            placeholder: false
        ),
        beginMeasurement: @escaping @Sendable () -> SanCovCounters.MeasurementContext = unimplemented(
            "beginMeasurement",
            placeholder: .testInstance()
        ),
        endMeasurement: @escaping @Sendable (SanCovCounters.MeasurementContext) -> Void = unimplemented(
            "endMeasurement"
        ),
        snapshotCoveredArraysWithContext: @escaping @Sendable (SanCovCounters.MeasurementContext) -> SparseCoverage? = unimplemented(
            "snapshotCoveredArraysWithContext",
            placeholder: nil
        )
    ) {
        self.snapshot = snapshot
        self.snapshotCoveredArrays = snapshotCoveredArrays
        self.isAvailable = isAvailable
        self.beginMeasurement = beginMeasurement
        self.endMeasurement = endMeasurement
        self.snapshotCoveredArraysWithContext = snapshotCoveredArraysWithContext
    }
}

// MARK: - Dependency Key

extension CoverageCountersClient: DependencyKey {
    public static let liveValue = CoverageCountersClient(
        snapshot: { SanCovCounters.snapshot() },
        snapshotCoveredArrays: { SanCovCounters.snapshotCoveredArrays() },
        isAvailable: { SanCovCounters.isAvailable },
        beginMeasurement: { SanCovCounters.beginMeasurement() },
        endMeasurement: { SanCovCounters.endMeasurement($0) },
        snapshotCoveredArraysWithContext: { SanCovCounters.snapshotCoveredArrays(with: $0) }
    )

    /// Test value uses live coverage counters since they're read-only and safe.
    /// For tests that need to control coverage behavior, override with a custom mock.
    public static let testValue = liveValue
}

extension DependencyValues {
    public var coverageCounters: CoverageCountersClient {
        get { self[CoverageCountersClient.self] }
        set { self[CoverageCountersClient.self] = newValue }
    }
}
