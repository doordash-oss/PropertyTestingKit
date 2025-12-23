//
//  CorpusSchema.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Foundation
import Dependencies

/// Utilities for generating schema versions from coverage mapping.
public enum CorpusSchema {
    /// Generate a schema version from the current coverage mapping.
    ///
    /// This creates a hash of the coverage structure so we can detect
    /// when code changes invalidate the corpus.
    public static func currentVersion() async -> String {
        @Dependency(\.coverageCounters) var coverageCounters
        return await currentVersion(using: coverageCounters)
    }

    /// Generate a schema version using a specific coverage counters client.
    /// This overload enables testing with mocked dependencies.
    public static func currentVersion(using coverageCounters: CoverageCountersClient) async -> String {
        // Use a hash of:
        // 1. Number of counters
        // 2. Build timestamp or similar

        guard let counters = await coverageCounters.snapshot() else {
            return "unknown"
        }

        // Simple version: just the counter count
        // In practice, we'd hash more metadata
        return "v1-\(counters.count)"
    }

    /// Check if a schema version is compatible with the current code.
    public static func isCompatible(_ version: String) async -> Bool {
        let current = await currentVersion()
        return version == current
    }
}
