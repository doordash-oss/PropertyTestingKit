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
///         .unsafeFlags(["-sanitize-coverage=edge,trace-cmp"])
///     ]
/// )
/// ```
public struct CoverageCountersClient: Sendable {
    /// Get a snapshot of current coverage counters for this task.
    public var snapshot: @Sendable () -> SanCovCounters?

    /// Reset coverage counters for the current task only.
    /// Other concurrent tasks are not affected.
    public var reset: @Sendable () -> Void

    /// Check if coverage instrumentation is available.
    public var isAvailable: @Sendable () -> Bool

    public init(
        snapshot: @escaping @Sendable () -> SanCovCounters? = unimplemented(
            "snapshot",
            placeholder: nil
        ),
        reset: @escaping @Sendable () -> Void = unimplemented("reset"),
        isAvailable: @escaping @Sendable () -> Bool = unimplemented(
            "isAvailable",
            placeholder: false
        )
    ) {
        self.snapshot = snapshot
        self.reset = reset
        self.isAvailable = isAvailable
    }
}

// MARK: - Dependency Key

extension CoverageCountersClient: DependencyKey {
    public static let liveValue = CoverageCountersClient(
        snapshot: { SanCovCounters.snapshot() },
        reset: { SanCovCounters.reset() },
        isAvailable: { SanCovCounters.isAvailable }
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
