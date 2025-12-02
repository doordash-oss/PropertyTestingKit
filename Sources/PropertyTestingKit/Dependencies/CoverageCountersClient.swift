//
//  CoverageCountersClient.swift
//  PropertyTestingKit
//
//  Dependency client for CoverageCounters to enable testing.
//

import Dependencies
import IssueReporting

/// Dependency client for coverage counter operations.
public struct CoverageCountersClient: Sendable {
    /// Get a snapshot of current coverage counters.
    public var snapshot: @Sendable () -> CoverageCounters?

    public init(
        snapshot: @escaping @Sendable () -> CoverageCounters? = unimplemented(
            "snapshot",
            placeholder: nil
        )
    ) {
        self.snapshot = snapshot
    }
}

// MARK: - Dependency Key

extension CoverageCountersClient: DependencyKey {
    public static let liveValue = CoverageCountersClient(
        snapshot: { CoverageCounters.snapshot() }
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
