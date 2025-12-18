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

    /// Get only the covered (non-zero) edge indices with their hit counts.
    /// More efficient than `snapshot()` when coverage is sparse.
    public var snapshotCoveredOnly: @Sendable () -> [Int: UInt8]?

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
        snapshotCoveredOnly: @escaping @Sendable () -> [Int: UInt8]? = unimplemented(
            "snapshotCoveredOnly",
            placeholder: nil
        ),
        reset: @escaping @Sendable () -> Void = unimplemented("reset"),
        isAvailable: @escaping @Sendable () -> Bool = unimplemented(
            "isAvailable",
            placeholder: false
        )
    ) {
        self.snapshot = snapshot
        self.snapshotCoveredOnly = snapshotCoveredOnly
        self.reset = reset
        self.isAvailable = isAvailable
    }

    /// Convenience initializer that derives `snapshotCoveredOnly` from `snapshot`.
    ///
    /// Use this when mocking in tests to avoid having to implement both methods.
    public init(
        snapshot: @escaping @Sendable () -> SanCovCounters?,
        reset: @escaping @Sendable () -> Void,
        isAvailable: @escaping @Sendable () -> Bool
    ) {
        self.snapshot = snapshot
        self.snapshotCoveredOnly = {
            guard let counters = snapshot() else { return nil }
            var result: [Int: UInt8] = [:]
            for (index, count) in counters.counters.enumerated() where count > 0 {
                result[index] = count
            }
            return result
        }
        self.reset = reset
        self.isAvailable = isAvailable
    }
}

// MARK: - Dependency Key

extension CoverageCountersClient: DependencyKey {
    public static let liveValue = CoverageCountersClient(
        snapshot: { SanCovCounters.snapshot() },
        snapshotCoveredOnly: { SanCovCounters.snapshotCoveredOnly() },
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
