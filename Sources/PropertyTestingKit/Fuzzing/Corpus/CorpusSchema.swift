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
    public static func currentVersion() -> String {
        @Dependency(\.coverageCounters) var coverageCounters
        return currentVersion(using: coverageCounters)
    }

    /// Generate a schema version using a specific coverage counters client.
    /// This overload enables testing with mocked dependencies.
    public static func currentVersion(using coverageCounters: CoverageCountersClient) -> String {
        // Use a hash of:
        // 1. Number of counters
        // 2. Build timestamp or similar

        // Simple version: just the counter count
        // In practice, we'd hash more metadata
        // TODO: This needs to be implemented so we refuzz less
        return "v1-0"
    }

    /// Check if a schema version is compatible with the current code.
    public static func isCompatible(_ version: String) async -> Bool {
        let current = currentVersion()
        return version == current
    }
}
