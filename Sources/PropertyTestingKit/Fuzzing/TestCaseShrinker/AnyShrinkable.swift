//
//  AnyShrinkable.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Foundation

/// Protocol for type-erased shrinking.
/// Allows runtime dispatch to the correct shrinking implementation.
protocol AnyShrinkable {
    func shrinkInContext(
        position: Int,
        values: inout [Any],
        typeErasedTest: @escaping ([Any]) async -> ShrinkResult,
        config: ShrinkConfig
    ) async -> ShrinkStats
}

/// Extension that provides shrinking for Shrinkable types.
extension AnyShrinkable where Self: Shrinkable & Sendable {
    func shrinkInContext(
        position: Int,
        values: inout [Any],
        typeErasedTest: @escaping ([Any]) async -> ShrinkResult,
        config: ShrinkConfig
    ) async -> ShrinkStats {
        let capturedValues = values

        // Shrink with a test that validates candidates in the full tuple context
        let (shrunk, componentStats) = await shrinkComponent(self, config: config) { candidate in
            // Build test array with candidate at this position
            var testValues = capturedValues
            testValues[position] = candidate
            return await typeErasedTest(testValues)
        }

        // Update the values array with the shrunk result
        values[position] = shrunk
        return componentStats
    }
}

// Make Array conform to AnyShrinkable when its elements are Hashable (proxy for shrinkable)
extension Array: AnyShrinkable where Element: Hashable {}

// Make String conform to AnyShrinkable
extension String: AnyShrinkable {}

// Make Data conform to AnyShrinkable
extension Data: AnyShrinkable {}

// MARK: - Shrinkable Extension

extension Shrinkable where Self: Sendable {
    /// Shrink this value while preserving a failure condition.
    ///
    /// - Parameters:
    ///   - config: Shrinking configuration.
    ///   - test: A function returning `.fail` if the candidate preserves the failure.
    /// - Returns: A minimized value that still triggers the failure.
    public func shrink(
        config: ShrinkConfig = ShrinkConfig(),
        test: @escaping (Self) async -> ShrinkResult
    ) async -> (minimized: Self, stats: ShrinkStats) {
        let shrinker = TestCaseShrinker<Self>(config: config)
        return await shrinker.shrink(input: self, test: test)
    }
}
