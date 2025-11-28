//
//  CoverageCounters.swift
//  PropertyTestingKit
//
//  In-memory coverage counter access without file I/O.
//

import Foundation
import PropertyTestingKitInternals

// MARK: - CoverageCounters

/// A snapshot of coverage counters captured directly from memory.
///
/// This provides zero-overhead coverage tracking without file I/O.
/// Use it to detect whether code executed between two points.
///
/// ## Usage
///
/// ```swift
/// // Capture counter state
/// let before = CoverageCounters.snapshot()
///
/// // Run code under test
/// myFunction()
///
/// // Capture after state and compare
/// let after = CoverageCounters.snapshot()
/// let diff = after.difference(from: before)
///
/// print("Executed \(diff.executedRegions) code regions")
/// print("Total executions: \(diff.totalExecutions)")
/// ```
///
/// - Note: Counter indices don't map directly to source lines.
///   They represent instrumented regions (branches, blocks, etc.).
public struct CoverageCounters: Sendable {
    /// The raw counter values.
    public let counters: [UInt64]

    /// Number of counters.
    public var count: Int { counters.count }

    /// Number of non-zero counters (regions that executed at least once).
    public var nonZeroCount: Int {
        counters.filter { $0 > 0 }.count
    }

    /// Sum of all counter values.
    public var totalExecutions: UInt64 {
        counters.reduce(0, +)
    }

    /// Create from raw counter array.
    init(counters: [UInt64]) {
        self.counters = counters
    }

    // MARK: - Snapshot

    /// Capture a snapshot of the current coverage counters.
    ///
    /// This reads directly from LLVM's in-memory counter array
    /// without any file I/O.
    ///
    /// - Returns: A snapshot of current counter values, or `nil` if
    ///   coverage instrumentation is not available.
    public static func snapshot() -> CoverageCounters? {
        guard CoverageTrait.isAvailable else { return nil }

        let begin = __llvm_profile_begin_counters()
        let end = __llvm_profile_end_counters()

        guard let begin = begin, let end = end else { return nil }

        let count = (end - begin)
        guard count > 0 else { return nil }

        // Copy counters to Swift array
        let buffer = UnsafeBufferPointer(start: begin, count: count)
        return CoverageCounters(counters: Array(buffer))
    }

    /// Capture a snapshot, resetting counters first.
    ///
    /// - Warning: This resets ALL coverage counters, which interferes with
    ///   Xcode and other coverage tools. Use `snapshot()` with difference-based
    ///   measurement instead.
    ///
    /// - Returns: A snapshot after reset (all zeros), or `nil` if unavailable.
    @available(*, deprecated, message: "Resetting counters interferes with Xcode coverage. Use snapshot() with difference-based measurement instead.")
    public static func snapshotAfterReset() -> CoverageCounters? {
        guard CoverageTrait.isAvailable else { return nil }
        __llvm_profile_reset_counters()
        return snapshot()
    }

    /// Reset all counters to zero.
    ///
    /// - Warning: This resets ALL coverage counters, which interferes with
    ///   Xcode and other coverage tools. Use difference-based measurement
    ///   (snapshot before, run code, snapshot after, compute diff) instead.
    @available(*, deprecated, message: "Resetting counters interferes with Xcode coverage. Use difference-based measurement instead.")
    public static func reset() {
        guard CoverageTrait.isAvailable else { return }
        __llvm_profile_reset_counters()
    }

    // MARK: - Comparison

    /// Compute the difference between this snapshot and an earlier one.
    ///
    /// - Parameter earlier: The earlier snapshot to compare against.
    /// - Returns: A diff showing what changed between the two snapshots.
    public func difference(from earlier: CoverageCounters) -> CounterDiff {
        // Handle different sizes (shouldn't happen normally)
        let maxCount = max(counters.count, earlier.counters.count)

        var changed: [Int] = []
        var newlyExecuted: [Int] = []
        var totalDelta: Int64 = 0

        for i in 0..<maxCount {
            let before = i < earlier.counters.count ? earlier.counters[i] : 0
            let after = i < counters.count ? counters[i] : 0

            if after != before {
                changed.append(i)
                totalDelta += Int64(after) - Int64(before)

                if before == 0 && after > 0 {
                    newlyExecuted.append(i)
                }
            }
        }

        return CounterDiff(
            changedIndices: changed,
            newlyExecutedIndices: newlyExecuted,
            totalDelta: totalDelta,
            before: earlier,
            after: self
        )
    }
}

// MARK: - CounterDiff

/// The difference between two coverage counter snapshots.
public struct CounterDiff: Sendable {
    /// Indices of counters that changed.
    public let changedIndices: [Int]

    /// Indices of counters that went from 0 to non-zero.
    public let newlyExecutedIndices: [Int]

    /// Sum of all counter changes (can be negative if counters were reset).
    public let totalDelta: Int64

    /// The earlier snapshot.
    public let before: CoverageCounters

    /// The later snapshot.
    public let after: CoverageCounters

    /// Number of regions that changed.
    public var changedCount: Int { changedIndices.count }

    /// Number of regions that were newly executed.
    public var executedRegions: Int { newlyExecutedIndices.count }

    /// Whether any code executed between the snapshots.
    public var hasChanges: Bool { !changedIndices.isEmpty }

    /// Get the execution count delta for a specific counter index.
    public func delta(at index: Int) -> Int64 {
        let beforeVal = index < before.counters.count ? before.counters[index] : 0
        let afterVal = index < after.counters.count ? after.counters[index] : 0
        return Int64(afterVal) - Int64(beforeVal)
    }
}

// MARK: - Convenience API

/// Execute a closure and capture the coverage counters that changed.
///
/// This is the simplest way to see what code executed:
///
/// ```swift
/// let diff = measureCoverage {
///     myFunction()
/// }
/// print("Executed \(diff.executedRegions) new regions")
/// ```
///
/// - Parameter body: The code to measure.
/// - Returns: The counter diff, or `nil` if coverage unavailable.
@discardableResult
public func measureCoverage(_ body: () throws -> Void) rethrows -> CounterDiff? {
    guard let before = CoverageCounters.snapshot() else { return nil }
    try body()
    guard let after = CoverageCounters.snapshot() else { return nil }
    return after.difference(from: before)
}

/// Execute a closure and capture the coverage counters that changed (async).
@discardableResult
public func measureCoverage(_ body: () async throws -> Void) async rethrows -> CounterDiff? {
    guard let before = CoverageCounters.snapshot() else { return nil }
    try await body()
    guard let after = CoverageCounters.snapshot() else { return nil }
    return after.difference(from: before)
}

/// Execute a closure with isolated coverage measurement.
///
/// - Note: This function now uses difference-based measurement instead of
///   resetting counters, to avoid interfering with Xcode and other coverage tools.
///   Use `measureCoverage` for the same functionality.
///
/// ```swift
/// let (result, diff) = measureIsolatedCoverage {
///     return myFunction()
/// }
/// ```
///
/// - Parameter body: The code to measure.
/// - Returns: Tuple of the result and counter diff.
@available(*, deprecated, message: "Use measureCoverage instead - this function no longer resets counters")
public func measureIsolatedCoverage<T>(
    _ body: () throws -> T
) rethrows -> (result: T, diff: CounterDiff?) {
    // No longer resets counters to avoid interfering with Xcode coverage
    guard let before = CoverageCounters.snapshot() else {
        return (try body(), nil)
    }
    let result = try body()
    guard let after = CoverageCounters.snapshot() else {
        return (result, nil)
    }
    return (result, after.difference(from: before))
}
