//
//  CoverageCountersClient.swift
//  PropertyTestingKit
//
//  Dependency client for task-isolated coverage counters.
//

import Dependencies
import IssueReporting

/// Dependency client for coverage counter operations.
///
/// Uses SanitizerCoverage with task-keyed maps for true per-task isolation.
/// This enables parallel fuzzing without coverage contamination.
///
/// ## Build Requirements
///
/// Your test target must be compiled with sanitizer coverage flags:
/// ```swift
/// .testTarget(
///     name: "MyTests",
///     swiftSettings: [
///         .unsafeFlags(["-sanitize-coverage=edge,pc-table"])
///     ]
/// )
/// ```
struct CoverageCountersClient: Sendable {
    /// Check if coverage instrumentation is available.
    var isAvailable: @Sendable () -> Bool

    /// Begin a measurement context for the current task.
    /// This creates an isolated coverage map and pre-warms caches for optimal performance.
    /// Must be paired with endMeasurement.
    var beginMeasurement: @Sendable () -> SanCovCounters.MeasurementContext

    /// End a measurement context and clean up resources.
    /// This frees the coverage map slot for reuse by other tasks.
    var endMeasurement: @Sendable (SanCovCounters.MeasurementContext) -> Void

    /// Reset coverage for a measurement context.
    /// This is a cheap memset operation - use between iterations instead of end+begin.
    var resetCoverage: @Sendable (SanCovCounters.MeasurementContext) -> Void

    /// Get covered indices using a specific measurement context.
    /// This bypasses TLS lookup, providing O(1) performance even after task hops.
    var snapshotCoveredArraysWithContext: @Sendable (SanCovCounters.MeasurementContext) throws -> SparseCoverage

    /// Access raw coverage data without creating a Swift array.
    /// Use this with Corpus.addIfInterestingRaw to avoid allocation when coverage isn't interesting.
    var withRawCoverage: @Sendable (SanCovCounters.MeasurementContext, @escaping (UnsafePointer<UInt32>?, Int) throws -> Bool) throws -> Bool

    /// Merge coverage directly into a bitmap. This is the fastest path - no allocation.
    /// Returns true if any new coverage was found.
    var mergeCoverageIntoBitmap: @Sendable (SanCovCounters.MeasurementContext, UnsafeMutablePointer<UInt64>, Int, Bool) -> Bool

    /// Compute signature hash from coverage data without allocation.
    /// This matches the SparseCoverage.signatureHash algorithm.
    var computeSignatureHash: @Sendable (SanCovCounters.MeasurementContext) -> Int

    init(
        isAvailable: @escaping @Sendable () -> Bool = unimplemented(
            "isAvailable",
            placeholder: false
        ),
        beginMeasurement: @escaping @Sendable () -> SanCovCounters.MeasurementContext = unimplemented(
            "beginMeasurement",
            placeholder: .testInstance()
        ),
        endMeasurement: @escaping @Sendable (SanCovCounters.MeasurementContext) -> Void = unimplemented(
            "endMeasurement"
        ),
        resetCoverage: @escaping @Sendable (SanCovCounters.MeasurementContext) -> Void = unimplemented(
            "resetCoverage"
        ),
        snapshotCoveredArraysWithContext: @escaping @Sendable (SanCovCounters.MeasurementContext) throws -> SparseCoverage = unimplemented(
            "snapshotCoveredArraysWithContext",
            placeholder: SparseCoverage()
        ),
        withRawCoverage: @escaping @Sendable (SanCovCounters.MeasurementContext, @escaping (UnsafePointer<UInt32>?, Int) throws -> Bool) throws -> Bool = unimplemented(
            "withRawCoverage",
            placeholder: false
        ),
        mergeCoverageIntoBitmap: @escaping @Sendable (SanCovCounters.MeasurementContext, UnsafeMutablePointer<UInt64>, Int, Bool) -> Bool = unimplemented(
            "mergeCoverageIntoBitmap",
            placeholder: false
        ),
        computeSignatureHash: @escaping @Sendable (SanCovCounters.MeasurementContext) -> Int = unimplemented(
            "computeSignatureHash",
            placeholder: 0
        )
    ) {
        self.isAvailable = isAvailable
        self.beginMeasurement = beginMeasurement
        self.endMeasurement = endMeasurement
        self.resetCoverage = resetCoverage
        self.snapshotCoveredArraysWithContext = snapshotCoveredArraysWithContext
        self.withRawCoverage = withRawCoverage
        self.mergeCoverageIntoBitmap = mergeCoverageIntoBitmap
        self.computeSignatureHash = computeSignatureHash
    }
}

// MARK: - Dependency Key

extension CoverageCountersClient: DependencyKey {
    static let liveValue = CoverageCountersClient(
        isAvailable: { SanCovCounters.isAvailable },
        beginMeasurement: { SanCovCounters.beginMeasurement() },
        endMeasurement: { SanCovCounters.endMeasurement($0) },
        resetCoverage: { SanCovCounters.resetCoverage($0) },
        snapshotCoveredArraysWithContext: { try SanCovCounters.snapshotCoveredArrays(with: $0) },
        withRawCoverage: { context, body in try SanCovCounters.withRawCoverage(context: context, body: body) },
        mergeCoverageIntoBitmap: { context, bitmap, wordCount, mergeAll in
            SanCovCounters.mergeCoverageIntoBitmap(context: context, bitmap: bitmap, wordCount: wordCount, mergeAll: mergeAll)
        },
        computeSignatureHash: { SanCovCounters.computeSignatureHash(context: $0) }
    )

    /// Test value uses live coverage counters since they're read-only and safe.
    /// For tests that need to control coverage behavior, override with a custom mock.
    static let testValue = liveValue
}

extension DependencyValues {
    var coverageCounters: CoverageCountersClient {
        get { self[CoverageCountersClient.self] }
        set { self[CoverageCountersClient.self] = newValue }
    }
}
