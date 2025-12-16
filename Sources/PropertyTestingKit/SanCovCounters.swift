//
//  SanCovCounters.swift
//  PropertyTestingKit
//
//  Task-isolated coverage counters using SanitizerCoverage.
//
//  Unlike LLVM's global profile counters, these use task-keyed maps
//  that provide true per-task isolation even when tasks share threads.
//  This enables parallel fuzzing without coverage contamination.
//

import Foundation
import ValueProfileHooks

// MARK: - SanCovCounters

/// A snapshot of coverage counters with task-level isolation.
///
/// Unlike `CoverageCounters` which uses LLVM's global profile counters,
/// `SanCovCounters` uses SanitizerCoverage's trace_pc_guard callbacks with
/// task-keyed maps. This provides true per-task isolation even when
/// Swift Testing runs tasks on shared threads.
///
/// ## How It Works
///
/// When your code is compiled with `-sanitize-coverage=edge`, LLVM instruments
/// every edge (branch) with a callback to `__sanitizer_cov_trace_pc_guard`.
/// Our implementation keys coverage maps by `swift_task_getCurrent()`, so each
/// Swift async task gets its own isolated coverage map.
///
/// ## Usage
///
/// ```swift
/// // Reset coverage for this task
/// SanCovCounters.reset()
///
/// // Run code under test
/// myFunction()
///
/// // Get coverage for this task only
/// let snapshot = SanCovCounters.snapshot()
/// print("Covered \(snapshot?.coveredCount ?? 0) edges")
/// ```
///
/// ## Build Requirements
///
/// Your test target must be compiled with sanitizer coverage flags:
/// ```swift
/// .testTarget(
///     name: "MyTests",
///     swiftSettings: [
///         .unsafeFlags([
///             "-sanitize-coverage=edge,trace-cmp"
///         ])
///     ]
/// )
/// ```
public struct SanCovCounters: Sendable {
    /// The raw counter values (0 = not executed, 1 = executed).
    public let counters: [UInt8]

    /// Number of instrumented edges.
    public var count: Int { counters.count }

    /// Number of edges that were executed (non-zero counters).
    public var coveredCount: Int {
        counters.filter { $0 > 0 }.count
    }

    /// The set of edge indices that were executed.
    public var coveredIndices: Set<Int> {
        var indices = Set<Int>()
        for (index, value) in counters.enumerated() where value > 0 {
            indices.insert(index)
        }
        return indices
    }

    /// Create from raw counter array.
    public init(counters: [UInt8]) {
        self.counters = counters
    }

    /// Create from UInt64 counters (for test compatibility).
    /// Values are clamped to UInt8.max.
    public init(counters: [UInt64]) {
        self.counters = counters.map { UInt8(min($0, UInt64(UInt8.max))) }
    }

    // MARK: - Static API

    /// Check if SanitizerCoverage counters are available.
    ///
    /// Returns `true` if the binary was compiled with sanitizer coverage flags
    /// and the counters have been initialized.
    public static var isAvailable: Bool {
        sancov_counters_available()
    }

    /// Get the total number of instrumented edges.
    public static var totalEdgeCount: Int {
        sancov_get_counter_count()
    }

    /// Reset coverage counters for the current task.
    ///
    /// This only affects the current Swift task's coverage map.
    /// Other tasks running concurrently are not affected.
    ///
    /// - Note: In non-async contexts, falls back to thread-local storage.
    public static func reset() {
        sancov_reset_counters()
    }

    /// Get the number of edges covered by the current task.
    ///
    /// This only counts coverage from the current Swift task.
    /// Coverage from other concurrent tasks is not included.
    public static var currentCoveredCount: Int {
        sancov_get_covered_count()
    }

    /// Capture a snapshot of the current task's coverage.
    ///
    /// Returns `nil` if SanitizerCoverage is not available.
    ///
    /// - Note: The snapshot is isolated to the current Swift task.
    public static func snapshot() -> SanCovCounters? {
        guard isAvailable else { return nil }

        let count = sancov_get_counter_count()
        guard count > 0 else { return nil }

        // Allocate buffer and copy counters
        var buffer = [UInt8](repeating: 0, count: count)
        let copied = sancov_snapshot_counters(&buffer, count)
        guard copied == count else { return nil }

        return SanCovCounters(counters: buffer)
    }

    // MARK: - Comparison

    /// Compute the difference between this snapshot and an earlier one.
    ///
    /// - Parameter earlier: The earlier snapshot to compare against.
    /// - Returns: A diff showing what changed between the two snapshots.
    public func difference(from earlier: SanCovCounters) -> SanCovDiff {
        let maxCount = max(counters.count, earlier.counters.count)

        var changed: [Int] = []
        var newlyCovered: [Int] = []

        for i in 0..<maxCount {
            let before = i < earlier.counters.count ? earlier.counters[i] : 0
            let after = i < counters.count ? counters[i] : 0

            if after != before {
                changed.append(i)
                if before == 0 && after > 0 {
                    newlyCovered.append(i)
                }
            }
        }

        return SanCovDiff(
            changedIndices: changed,
            newlyCoveredIndices: newlyCovered,
            before: earlier,
            after: self
        )
    }
}

// MARK: - SanCovDiff

/// The difference between two SanCovCounters snapshots.
public struct SanCovDiff: Sendable {
    /// Indices of counters that changed.
    public let changedIndices: [Int]

    /// Indices of counters that went from 0 to non-zero.
    public let newlyCoveredIndices: [Int]

    /// The earlier snapshot.
    public let before: SanCovCounters

    /// The later snapshot.
    public let after: SanCovCounters

    /// Number of edges that changed.
    public var changedCount: Int { changedIndices.count }

    /// Number of edges that were newly covered.
    public var newlyCoveredCount: Int { newlyCoveredIndices.count }

    /// Whether any coverage changed between the snapshots.
    public var hasChanges: Bool { !changedIndices.isEmpty }
}

// MARK: - Convenience API

/// Execute a closure and capture the coverage that changed (task-isolated).
///
/// This uses SanitizerCoverage with task-keyed maps, providing true
/// per-task isolation. Multiple tests can run in parallel without
/// coverage contamination.
///
/// ```swift
/// let diff = measureSanCoverage {
///     myFunction()
/// }
/// print("Covered \(diff?.newlyCoveredCount ?? 0) new edges")
/// ```
///
/// - Parameter body: The code to measure.
/// - Returns: The coverage diff, or `nil` if SanCov unavailable.
@discardableResult
public func measureSanCoverage(_ body: () throws -> Void) rethrows -> SanCovDiff? {
    guard SanCovCounters.isAvailable else { return nil }

    let before = SanCovCounters.snapshot()
    try body()
    let after = SanCovCounters.snapshot()

    guard let before = before, let after = after else { return nil }
    return after.difference(from: before)
}

/// Execute an async closure and capture the coverage that changed (task-isolated).
///
/// - Note: Coverage remains isolated to the current task even across
///   suspension points where the task may hop threads.
@discardableResult
public func measureSanCoverage(_ body: () async throws -> Void) async rethrows -> SanCovDiff? {
    guard SanCovCounters.isAvailable else { return nil }

    let before = SanCovCounters.snapshot()
    try await body()
    let after = SanCovCounters.snapshot()

    guard let before = before, let after = after else { return nil }
    return after.difference(from: before)
}

// MARK: - Source Location Mapping

/// Source location information for a covered edge.
///
/// Maps a SanCov edge index to its source location using debug symbol info.
/// This provides function-level granularity (file + function name).
public struct SanCovSourceLocation: Sendable {
    /// The source file path containing this edge.
    public let filename: String?

    /// The function name containing this edge.
    public let functionName: String?

    /// The program counter (instruction address) for this edge.
    public let pc: UInt

    /// The SanCov edge index.
    public let edgeIndex: UInt32

    fileprivate init(from cLocation: SanCovSourceLocation_C) {
        self.filename = cLocation.filename.map { String(cString: $0) }
        self.functionName = cLocation.function_name.map { String(cString: $0) }
        self.pc = UInt(cLocation.pc)
        self.edgeIndex = cLocation.edge_index
    }
}

// Type alias to avoid ambiguity with C struct
private typealias SanCovSourceLocation_C = ValueProfileHooks.SanCovSourceLocation

extension SanCovCounters {
    /// Check if PC-to-source mapping is available.
    public static var pcsAvailable: Bool {
        sancov_pcs_available()
    }

    /// Get the program counter for a given edge index.
    ///
    /// - Parameter edgeIndex: The edge index to look up.
    /// - Returns: The PC value, or 0 if unavailable.
    public static func getPC(for edgeIndex: Int) -> UInt {
        UInt(sancov_get_pc(edgeIndex))
    }

    /// Get source location info for a given edge index.
    ///
    /// - Parameter edgeIndex: The edge index to look up.
    /// - Returns: Source location info, or nil if unavailable.
    public static func getSourceLocation(for edgeIndex: Int) -> SanCovSourceLocation? {
        var cLocation = SanCovSourceLocation_C()
        guard sancov_get_source_location(edgeIndex, &cLocation) else {
            return nil
        }
        return SanCovSourceLocation(from: cLocation)
    }

    /// Get source locations for all covered edges in the current task.
    ///
    /// This provides task-isolated coverage with source mapping.
    /// Each location includes the file path and function name where the edge resides.
    ///
    /// - Returns: Array of source locations for covered edges.
    public static func getCoveredLocations() -> [SanCovSourceLocation] {
        // First, get the count
        let count = sancov_get_covered_locations(nil, 0)
        guard count > 0 else { return [] }

        // Allocate buffer and get locations
        var cLocations = [SanCovSourceLocation_C](repeating: SanCovSourceLocation_C(), count: count)
        let filled = sancov_get_covered_locations(&cLocations, count)

        // Convert to Swift types
        return cLocations.prefix(filled).map { SanCovSourceLocation(from: $0) }
    }
}

/// Coverage result with source-mapped locations (task-isolated).
public struct SanCovSourceCoverage: Sendable {
    /// All covered source locations.
    public let coveredLocations: [SanCovSourceLocation]

    /// Number of edges covered.
    public var coveredCount: Int { coveredLocations.count }

    /// Coverage grouped by file.
    public var byFile: [String: [SanCovSourceLocation]] {
        Dictionary(grouping: coveredLocations.filter { $0.filename != nil }) {
            $0.filename!
        }
    }

    /// Coverage grouped by function.
    public var byFunction: [String: [SanCovSourceLocation]] {
        Dictionary(grouping: coveredLocations.filter { $0.functionName != nil }) {
            $0.functionName!
        }
    }

    /// Get all unique files that were covered.
    public var coveredFiles: Set<String> {
        Set(coveredLocations.compactMap { $0.filename })
    }

    /// Get all unique functions that were covered.
    public var coveredFunctions: Set<String> {
        Set(coveredLocations.compactMap { $0.functionName })
    }
}

/// Measure coverage with source location mapping (task-isolated).
///
/// This combines task-isolated SanCov coverage with source location mapping.
/// Coverage is isolated to the current task, allowing parallel test execution
/// without contamination.
///
/// ```swift
/// let coverage = measureSanCovSourceCoverage {
///     myFunction()
/// }
/// for file in coverage?.coveredFiles ?? [] {
///     print("Covered: \(file)")
/// }
/// ```
///
/// - Parameter body: The code to measure.
/// - Returns: Source-mapped coverage, or nil if SanCov unavailable.
@discardableResult
public func measureSanCovSourceCoverage(_ body: () throws -> Void) rethrows -> SanCovSourceCoverage? {
    guard SanCovCounters.isAvailable else { return nil }

    // Reset task-isolated counters
    SanCovCounters.reset()

    // Run the code
    try body()

    // Get source-mapped coverage
    let locations = SanCovCounters.getCoveredLocations()
    return SanCovSourceCoverage(coveredLocations: locations)
}

/// Measure coverage with source location mapping (task-isolated, async).
@discardableResult
public func measureSanCovSourceCoverage(_ body: () async throws -> Void) async rethrows -> SanCovSourceCoverage? {
    guard SanCovCounters.isAvailable else { return nil }

    // Reset task-isolated counters
    SanCovCounters.reset()

    // Run the code
    try await body()

    // Get source-mapped coverage
    let locations = SanCovCounters.getCoveredLocations()
    return SanCovSourceCoverage(coveredLocations: locations)
}
