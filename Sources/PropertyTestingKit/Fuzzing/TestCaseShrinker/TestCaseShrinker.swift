//
//  TestCaseShrinker.swift
//  PropertyTestingKit
//
//  Test case shrinking / delta debugging for failure minimization.
//
//  Based on:
//  - Zeller & Hildebrandt (2002) "Delta Debugging: Simplifying and Isolating Failure-Inducing Input"
//  - MacIver & Donaldson (2020) "Test-Case Reduction via Test-Case Generation"
//
//  The key insight is that large failing inputs obscure the root cause. By systematically
//  reducing inputs while preserving the failure, we can find minimal examples that
//  make debugging much easier.
//

import Foundation
import Dependencies
import Testing

/// A delta-debugging-based test case shrinker.
///
/// Systematically reduces failing inputs by:
/// 1. Trying to remove chunks of the input
/// 2. Trying to simplify remaining elements
/// 3. Iterating until a local minimum is found
///
/// ## Usage
///
/// ```swift
/// let shrinker = TestCaseShrinker<[Int]>(config: ShrinkConfig())
/// let minimized = shrinker.shrink(
///     input: failingArray,
///     test: { candidate in
///         do {
///             try propertyTest(candidate)
///             return .pass
///         } catch {
///             return .fail  // Same error = preserve
///         }
///     }
/// )
/// ```
struct TestCaseShrinker<T: Shrinkable & Sendable>: Sendable {
    @Dependency(\.dateClient) var dateClient
    private let config: ShrinkConfig

    public init(config: ShrinkConfig = ShrinkConfig()) {
        self.config = config
    }

    /// Shrink a failing input to a minimal form.
    ///
    /// - Parameters:
    ///   - input: The failing input to minimize.
    ///   - test: A function that returns `.fail` if the candidate preserves the failure.
    /// - Returns: A tuple of (minimized input, statistics).
    public func shrink(
        input: T,
        test: @escaping (T) async -> ShrinkResult
    ) async -> (minimized: T, stats: ShrinkStats) {
        let startTime = dateClient.now()
        var current = input
        var candidatesTested = 0
        var timedOut = false
        var maxExecutionsReached = false

        // Phase 1: Delta debugging - try removing chunks
        var granularity = config.initialGranularity
        var improved = true

        while improved && granularity >= config.minGranularity {
            improved = false
            let elementCount = current.shrinkableElementCount

            guard elementCount > 0 else { break }

            // Calculate chunk size
            let chunkSize = max(1, elementCount / granularity)
            var offset = 0

            while offset < current.shrinkableElementCount {
                // Check stopping conditions
                if dateClient.now().timeIntervalSince(startTime) >= config.timeout {
                    timedOut = true
                    break
                }
                if candidatesTested >= config.maxExecutions {
                    maxExecutionsReached = true
                    break
                }

                let removeStart = offset
                let removeEnd = min(offset + chunkSize, current.shrinkableElementCount)
                let range = removeStart..<removeEnd

                if let candidate = current.candidateRemovingRange(range) {
                    candidatesTested += 1
                    let result = await test(candidate)

                    if result == .fail {
                        // Candidate preserves failure - accept it
                        current = candidate
                        improved = true
                        if config.verbose {
                            print("[Shrink] Removed range \(range), new size: \(current.shrinkableElementCount)")
                        }
                        // Don't increment offset - try removing at same position again
                        continue
                    }
                }

                offset += chunkSize
            }

            if timedOut || maxExecutionsReached { break }

            // Increase granularity if no improvement at current level
            if !improved && granularity < current.shrinkableElementCount {
                granularity *= 2
                improved = true // Try again with finer granularity
            }
        }

        // Phase 2: Try simplifying individual elements
        if !timedOut && !maxExecutionsReached {
            for candidate in current.simplifiedCandidates() {
                if candidatesTested >= config.maxExecutions {
                    maxExecutionsReached = true
                    break
                }
                if dateClient.now().timeIntervalSince(startTime) >= config.timeout {
                    timedOut = true
                    break
                }

                candidatesTested += 1
                if await test(candidate) == .fail {
                    current = candidate
                    if config.verbose {
                        print("[Shrink] Simplified to size: \(current.shrinkableElementCount)")
                    }
                }
            }
        }

        let duration = dateClient.now().timeIntervalSince(startTime)
        let stats = ShrinkStats(
            candidatesTested: candidatesTested,
            originalSize: input.shrinkableElementCount,
            minimizedSize: current.shrinkableElementCount,
            duration: duration,
            timedOut: timedOut,
            maxExecutionsReached: maxExecutionsReached
        )

        return (current, stats)
    }

    /// Shrink a failing input using a void-returning test.
    ///
    /// This overload accepts tests that throw or record issues via `#expect`.
    /// A candidate is considered to preserve the failure if:
    /// - The test throws an error, OR
    /// - The test records any issues via Swift Testing's `#expect` or `Issue.record`
    ///
    /// - Parameters:
    ///   - input: The failing input to minimize.
    ///   - test: A void-returning test function that throws or records issues on failure.
    /// - Returns: A tuple of (minimized input, statistics).
    public func shrink(
        input: T,
        test: @escaping (T) async throws -> Void
    ) async -> (minimized: T, stats: ShrinkStats) {
        await shrink(input: input) { candidate in
            await testToShrinkResult(candidate: candidate, test: test)
        }
    }
}

// MARK: - Test Result Conversion

/// Convert a void-returning test to a `ShrinkResult`.
///
/// Detects failures from:
/// 1. Thrown errors
/// 2. Issues recorded via `#expect` or `Issue.record`
///
/// - Parameters:
///   - candidate: The input to test.
///   - test: A void-returning test function.
/// - Returns: `.fail` if the test throws or records issues, `.pass` otherwise.
func testToShrinkResult<T: Sendable>(
    candidate: T,
    test: @escaping (T) async throws -> Void
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

// MARK: - Component Shrinking (Overload Resolution)

/// Shrink a single component that conforms to Shrinkable.
/// The compiler selects this overload for Shrinkable types.
func shrinkComponent<T: Shrinkable & Sendable>(
    _ value: T,
    config: ShrinkConfig,
    test: @escaping (T) async -> ShrinkResult
) async -> (T, ShrinkStats) {
    let shrinker = TestCaseShrinker<T>(config: config)
    return await shrinker.shrink(input: value, test: test)
}

/// No-op shrink for types that don't conform to Shrinkable.
/// The compiler selects this overload as a fallback.
func shrinkComponent<T: Sendable>(
    _ value: T,
    config: ShrinkConfig,
    test: @escaping (T) async -> ShrinkResult
) async -> (T, ShrinkStats) {
    // Can't shrink non-Shrinkable types, return unchanged
    return (value, .empty)
}
