//
//  MultiComponentShrinker.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Foundation
import Dependencies
import Testing

/// Shrinker for multi-component inputs (tuples).
///
/// Uses parameter packs to shrink any number of components.
/// Components that conform to Shrinkable are shrunk; others are left unchanged.
struct MultiComponentShrinker: Sendable {
    @Dependency(\.dateClient) var dateClient

    private let config: ShrinkConfig

    init(config: ShrinkConfig = ShrinkConfig()) {
        self.config = config
    }

    /// Shrink a multi-component input using parameter packs.
    ///
    /// Each component is shrunk in the context of the full tuple. When testing
    /// a candidate for one component, the other components retain their current
    /// (possibly already shrunk) values. This ensures the failure condition is
    /// preserved throughout the shrinking process.
    // TODO: make this use parameter packs like we did in FuzzEngine
    func shrink<each T: Sendable>(
        input: (repeat each T),
        test: @escaping ((repeat each T)) async -> ShrinkResult
    ) async -> (minimized: (repeat each T), stats: ShrinkStats) {
        let startTime = dateClient.now()

        // Store values in a mutable array for position-based access
        var values: [Any] = []
        _ = (repeat { values.append(each input); return () }())

        // Track stats from each component
        var allStats: [ShrinkStats] = []

        // Create a type-erased test function that builds tuples from the values array
        let typeErasedTest: ([Any]) async -> ShrinkResult = { testValues in
            let testTuple: (repeat each T) = buildTupleFromArray(testValues, as: (repeat each T).self)
            return await test(testTuple)
        }

        // Shrink each component sequentially
        var position = 0
        _ = (repeat await shrinkComponentInContext(
            element: each input,
            position: { let p = position; position += 1; return p }(),
            values: &values,
            typeErasedTest: typeErasedTest,
            config: config,
            stats: &allStats
        ))

        // Reconstruct the minimized tuple from the values array
        let minimized: (repeat each T) = buildTupleFromArray(values, as: (repeat each T).self)

        // Calculate aggregate stats
        let duration = dateClient.now().timeIntervalSince(startTime)
        let combinedStats = ShrinkStats(
            candidatesTested: allStats.reduce(0) { $0 + $1.candidatesTested },
            originalSize: allStats.reduce(0) { $0 + $1.originalSize },
            minimizedSize: allStats.reduce(0) { $0 + $1.minimizedSize },
            duration: duration,
            timedOut: allStats.contains { $0.timedOut },
            maxExecutionsReached: allStats.contains { $0.maxExecutionsReached }
        )

        return (minimized, combinedStats)
    }

    /// Shrink a multi-component input using a void-returning test.
    ///
    /// This overload accepts tests that throw or record issues via `#expect`.
    /// A candidate tuple is considered to preserve the failure if:
    /// - The test throws an error, OR
    /// - The test records any issues via Swift Testing's `#expect` or `Issue.record`
    ///
    /// - Parameters:
    ///   - input: The failing input tuple to minimize.
    ///   - test: A void-returning test function that throws or records issues on failure.
    /// - Returns: A tuple of (minimized input, statistics).
    func shrink<each T: Sendable>(
        input: (repeat each T),
        test: @escaping ((repeat each T)) async throws -> Void
    ) async -> (minimized: (repeat each T), stats: ShrinkStats) {
        await shrink(input: input) { candidate in
            await tupleTestToShrinkResult(candidate: candidate, test: test)
        }
    }

    /// Helper to build a tuple from an array of values.
    /// Uses an immediately-invoked closure to maintain an index during pack expansion.
    private func buildTupleFromArray<each U: Sendable>(
        _ values: [Any],
        as type: (repeat each U).Type
    ) -> (repeat each U) {
        var extractIdx = 0
        return (repeat {
            let val = values[extractIdx]
            extractIdx += 1
            return val as! (each U)
        }())
    }

    /// Shrink a component using runtime type checking for Shrinkable conformance.
    private func shrinkComponentInContext<T: Sendable>(
        element: T,
        position: Int,
        values: inout [Any],
        typeErasedTest: @escaping ([Any]) async -> ShrinkResult,
        config: ShrinkConfig,
        stats: inout [ShrinkStats]
    ) async {
        // Check if the element conforms to AnyShrinkable at runtime
        if let shrinkable = element as? AnyShrinkable {
            let componentStats = await shrinkable.shrinkInContext(
                position: position,
                values: &values,
                typeErasedTest: typeErasedTest,
                config: config
            )
            stats.append(componentStats)
        } else {
            // Non-shrinkable type - leave unchanged
            stats.append(.empty)
        }
    }
}

// MARK: - Tuple Test Result Conversion

/// Convert a void-returning tuple test to a `ShrinkResult`.
///
/// Detects failures from:
/// 1. Thrown errors
/// 2. Issues recorded via `#expect` or `Issue.record`
///
/// - Parameters:
///   - candidate: The tuple input to test.
///   - test: A void-returning test function.
/// - Returns: `.fail` if the test throws or records issues, `.pass` otherwise.
func tupleTestToShrinkResult<each T: Sendable>(
    candidate: (repeat each T),
    test: @escaping ((repeat each T)) async throws -> Void
) async -> ShrinkResult {
    do {
        let issueRecorded = try await hasIssues {
            try await test(candidate)
        }
        return issueRecorded ? .fail : .pass
    } catch {
        // Test threw an error - this is a failure
        return .fail
    }
}
