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

// MARK: - ShrinkResult

/// The result of testing a candidate during shrinking.
public enum ShrinkResult: Sendable {
    /// Test passed (no failure) - this candidate doesn't preserve the property.
    case pass

    /// Test failed as expected - this candidate preserves the failure.
    case fail

    /// Test behaved unexpectedly (timeout, different error, exception).
    case unresolved
}

// MARK: - ShrinkConfig

/// Configuration for test case shrinking.
public struct ShrinkConfig: Sendable {
    /// Maximum number of test executions during shrinking.
    /// Prevents runaway shrinking on complex inputs.
    public var maxExecutions: Int

    /// Maximum time to spend shrinking.
    public var timeout: TimeInterval

    /// Whether to enable verbose logging during shrinking.
    public var verbose: Bool

    /// Initial granularity for delta debugging (number of partitions).
    /// Larger values find smaller reductions faster but may miss some.
    public var initialGranularity: Int

    /// Minimum granularity (stop subdividing when partitions reach this size).
    public var minGranularity: Int

    public init(
        maxExecutions: Int = 1000,
        timeout: TimeInterval = 30,
        verbose: Bool = false,
        initialGranularity: Int = 2,
        minGranularity: Int = 1
    ) {
        self.maxExecutions = maxExecutions
        self.timeout = timeout
        self.verbose = verbose
        self.initialGranularity = max(2, initialGranularity)
        self.minGranularity = max(1, minGranularity)
    }
}

// MARK: - ShrinkStats

/// Statistics about a shrinking run.
public struct ShrinkStats: Sendable {
    /// Number of candidates tested.
    public let candidatesTested: Int

    /// Original input size (element count).
    public let originalSize: Int

    /// Minimized input size (element count).
    public let minimizedSize: Int

    /// Time spent shrinking.
    public let duration: TimeInterval

    /// Whether shrinking timed out.
    public let timedOut: Bool

    /// Whether max executions was reached.
    public let maxExecutionsReached: Bool

    /// Reduction ratio (0.0 = no reduction, 1.0 = reduced to nothing).
    public var reductionRatio: Double {
        guard originalSize > 0 else { return 0 }
        return 1.0 - Double(minimizedSize) / Double(originalSize)
    }

    /// Generate a human-readable report.
    public func report() -> String {
        var lines: [String] = []
        lines.append("Shrinking Statistics:")
        lines.append("  Original size: \(originalSize) elements")
        lines.append("  Minimized size: \(minimizedSize) elements")
        lines.append("  Reduction: \(String(format: "%.1f%%", reductionRatio * 100))")
        lines.append("  Candidates tested: \(candidatesTested)")
        lines.append("  Duration: \(String(format: "%.2fs", duration))")
        if timedOut {
            lines.append("  Note: Shrinking timed out")
        }
        if maxExecutionsReached {
            lines.append("  Note: Max executions reached")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Shrinkable Protocol

/// A type that can be shrunk (reduced to simpler/smaller forms).
///
/// Provides structure-aware shrinking for complex types.
public protocol Shrinkable {
    /// Number of elements that can potentially be removed.
    var shrinkableElementCount: Int { get }

    /// Generate candidates by removing a range of elements.
    /// - Parameter range: The range of element indices to remove.
    /// - Returns: A candidate with those elements removed, or nil if not possible.
    func candidateRemovingRange(_ range: Range<Int>) -> Self?

    /// Generate candidates by simplifying elements (without removing them).
    /// - Returns: Array of simplified candidates.
    func simplifiedCandidates() -> [Self]
}

// MARK: - Default Shrinkable Conformances

extension Array: Shrinkable {
    public var shrinkableElementCount: Int { count }

    public func candidateRemovingRange(_ range: Range<Int>) -> [Element]? {
        guard range.lowerBound >= 0, range.upperBound <= count else { return nil }
        var copy = self
        copy.removeSubrange(range)
        return copy
    }

    public func simplifiedCandidates() -> [[Element]] {
        // For arrays, simplification is removal, which is handled by candidateRemovingRange
        []
    }
}

extension String: Shrinkable {
    public var shrinkableElementCount: Int { count }

    public func candidateRemovingRange(_ range: Range<Int>) -> String? {
        let startIndex = self.index(self.startIndex, offsetBy: range.lowerBound, limitedBy: self.endIndex)
        let endIndex = self.index(self.startIndex, offsetBy: range.upperBound, limitedBy: self.endIndex)
        guard let start = startIndex, let end = endIndex else { return nil }

        var copy = self
        copy.removeSubrange(start..<end)
        return copy
    }

    public func simplifiedCandidates() -> [String] {
        var candidates: [String] = []

        // Try replacing uppercase with lowercase
        let lowercased = self.lowercased()
        if lowercased != self {
            candidates.append(lowercased)
        }

        // Try replacing all characters with 'a'
        let simplified = String(repeating: "a", count: self.count)
        if simplified != self {
            candidates.append(simplified)
        }

        // Try empty string
        if !self.isEmpty {
            candidates.append("")
        }

        return candidates
    }
}

extension Data: Shrinkable {
    public var shrinkableElementCount: Int { count }

    public func candidateRemovingRange(_ range: Range<Int>) -> Data? {
        guard range.lowerBound >= 0, range.upperBound <= count else { return nil }
        var copy = self
        copy.removeSubrange(range)
        return copy
    }

    public func simplifiedCandidates() -> [Data] {
        // Try zeroing out the data
        if self != Data(repeating: 0, count: self.count) {
            return [Data(repeating: 0, count: self.count)]
        }
        return []
    }
}

// MARK: - Integer Shrinkable

/// Helper for shrinking integer types.
public struct IntegerShrinker {
    /// Generate smaller integer candidates for fixed-width integers.
    public static func candidates<T: FixedWidthInteger>(for value: T, toward target: T = 0) -> [T] {
        var candidates: [T] = []

        // Try the target directly
        if value != target {
            candidates.append(target)
        }

        // Binary search toward target
        if value > target {
            var low = target
            let high = value
            while low < high {
                let mid = low + (high - low) / 2
                if mid != value {
                    candidates.append(mid)
                }
                low = mid + 1
            }
        } else if value < target {
            let low = value
            var high = target
            while low < high {
                let mid = low + (high - low) / 2
                if mid != value {
                    candidates.append(mid)
                }
                high = mid
            }
        }

        // Try halving
        if value != 0 {
            candidates.append(value / 2)
        }

        // Try subtracting 1
        if value > T.min + 1 {
            candidates.append(value - 1)
        }

        // Try negation (for signed types)
        if T.isSigned {
            let negated = 0 &- value
            if negated != value {
                candidates.append(negated)
            }
        }

        return Array(Set(candidates)).filter { $0 != value }
    }
}

// MARK: - TestCaseShrinker

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
public struct TestCaseShrinker<T: Shrinkable & Sendable>: Sendable {
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
        test: @escaping (T) -> ShrinkResult
    ) -> (minimized: T, stats: ShrinkStats) {
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
                    let result = test(candidate)

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
                if test(candidate) == .fail {
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
}

// MARK: - Multi-Component Shrinker

/// Shrinker for multi-component inputs (tuples, structs).
///
/// Tries shrinking each component independently and in combination.
public struct MultiComponentShrinker: Sendable {
    @Dependency(\.dateClient) var dateClient

    private let config: ShrinkConfig

    public init(config: ShrinkConfig = ShrinkConfig()) {
        self.config = config
    }

    /// Shrink a two-component input.
    public func shrink<A: Shrinkable & Sendable, B: Shrinkable & Sendable>(
        input: (A, B),
        test: @escaping ((A, B)) -> ShrinkResult
    ) -> (minimized: (A, B), stats: ShrinkStats) {
        let startTime = dateClient.now()
        var current = input
        var candidatesTested = 0
        var timedOut = false
        var maxExecutionsReached = false

        // Shrink first component
        let shrinkerA = TestCaseShrinker<A>(config: config)
        let (shrunkA, statsA) = shrinkerA.shrink(input: current.0) { candidate in
            test((candidate, current.1))
        }
        current.0 = shrunkA
        candidatesTested += statsA.candidatesTested

        // Shrink second component
        if !statsA.timedOut && !statsA.maxExecutionsReached {
            let remainingConfig = ShrinkConfig(
                maxExecutions: config.maxExecutions - candidatesTested,
                timeout: config.timeout - statsA.duration,
                verbose: config.verbose,
                initialGranularity: config.initialGranularity,
                minGranularity: config.minGranularity
            )
            let shrinkerB = TestCaseShrinker<B>(config: remainingConfig)
            let (shrunkB, statsB) = shrinkerB.shrink(input: current.1) { candidate in
                test((current.0, candidate))
            }
            current.1 = shrunkB
            candidatesTested += statsB.candidatesTested
            timedOut = statsB.timedOut
            maxExecutionsReached = statsB.maxExecutionsReached
        } else {
            timedOut = statsA.timedOut
            maxExecutionsReached = statsA.maxExecutionsReached
        }

        let duration = dateClient.now().timeIntervalSince(startTime)
        let stats = ShrinkStats(
            candidatesTested: candidatesTested,
            originalSize: input.0.shrinkableElementCount + input.1.shrinkableElementCount,
            minimizedSize: current.0.shrinkableElementCount + current.1.shrinkableElementCount,
            duration: duration,
            timedOut: timedOut,
            maxExecutionsReached: maxExecutionsReached
        )

        return (current, stats)
    }
}

// MARK: - Fuzzable Extension for Shrinking

extension Fuzzable where Self: Shrinkable & Sendable {
    /// Shrink this value while preserving a failure condition.
    ///
    /// - Parameters:
    ///   - config: Shrinking configuration.
    ///   - test: A function returning `.fail` if the candidate preserves the failure.
    /// - Returns: A minimized value that still triggers the failure.
    public func shrink(
        config: ShrinkConfig = ShrinkConfig(),
        test: @escaping (Self) -> ShrinkResult
    ) -> (minimized: Self, stats: ShrinkStats) {
        let shrinker = TestCaseShrinker<Self>(config: config)
        return shrinker.shrink(input: self, test: test)
    }
}

// MARK: - Integer Shrinking

/// Wrapper for shrinking integer values.
public struct ShrinkableInt: Shrinkable, Sendable {
    public let value: Int

    public init(_ value: Int) {
        self.value = value
    }

    public var shrinkableElementCount: Int {
        // Treat absolute value as "size" for shrinking purposes
        abs(value)
    }

    public func candidateRemovingRange(_ range: Range<Int>) -> ShrinkableInt? {
        // For integers, we don't remove ranges - we generate simpler values
        nil
    }

    public func simplifiedCandidates() -> [ShrinkableInt] {
        IntegerShrinker.candidates(for: value).map { ShrinkableInt($0) }
    }
}

// MARK: - Shrink Helper Functions

/// Shrink a failing input to produce a minimal example.
///
/// Use this function to minimize any failing input that caused a test failure.
///
/// - Parameters:
///   - input: The input that triggered the failure.
///   - config: Shrinking configuration.
///   - test: A function that returns `.fail` if the candidate preserves the failure.
/// - Returns: A tuple of (minimized input, shrinking statistics).
public func shrinkFailingInput<T: Shrinkable & Sendable>(
    _ input: T,
    config: ShrinkConfig = ShrinkConfig(),
    test: @escaping (T) -> ShrinkResult
) -> (minimized: T, stats: ShrinkStats) {
    let shrinker = TestCaseShrinker<T>(config: config)
    return shrinker.shrink(input: input, test: test)
}
