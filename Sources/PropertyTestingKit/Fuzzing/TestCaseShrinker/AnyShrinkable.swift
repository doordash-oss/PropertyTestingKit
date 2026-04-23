// Copyright 2026 DoorDash, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

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
    func shrink(
        config: ShrinkConfig = ShrinkConfig(),
        test: @escaping (Self) async -> ShrinkResult
    ) async -> (minimized: Self, stats: ShrinkStats) {
        let shrinker = TestCaseShrinker<Self>(config: config)
        return await shrinker.shrink(input: self, test: test)
    }
}
