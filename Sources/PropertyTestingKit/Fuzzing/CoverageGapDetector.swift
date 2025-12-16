//
//  CoverageGapDetector.swift
//  PropertyTestingKit
//
//  Detects coverage gaps in partially-covered functions.
//

import Foundation

// MARK: - Coverage Gap Types

/// An uncovered region within a partially-covered function.
public struct UncoveredRegion: Sendable, Equatable {
    /// Starting line (1-indexed).
    public let lineStart: UInt32

    /// Starting column (1-indexed).
    public let columnStart: UInt32

    /// Ending line (1-indexed).
    public let lineEnd: UInt32

    /// Ending column (1-indexed).
    public let columnEnd: UInt32

    /// Whether this is a branch region (e.g., if/else, switch case).
    public let isBranch: Bool

    public init(
        lineStart: UInt32,
        columnStart: UInt32,
        lineEnd: UInt32,
        columnEnd: UInt32,
        isBranch: Bool
    ) {
        self.lineStart = lineStart
        self.columnStart = columnStart
        self.lineEnd = lineEnd
        self.columnEnd = columnEnd
        self.isBranch = isBranch
    }
}

/// A coverage gap in a partially-covered function.
///
/// This represents a function that has some coverage but not complete coverage,
/// indicating potential missing test cases or mutation strategies.
public struct CoverageGap: Sendable {
    /// The function name (demangled).
    public let functionName: String

    /// Source file path containing this function.
    public let filename: String

    /// Regions within this function that were not executed.
    public let uncoveredRegions: [UncoveredRegion]

    /// Number of regions that were covered.
    public let coveredRegionCount: Int

    /// Total number of regions in this function.
    public let totalRegionCount: Int

    /// Coverage percentage (0-100).
    public var coveragePercentage: Double {
        totalRegionCount > 0 ? Double(coveredRegionCount) / Double(totalRegionCount) * 100 : 0
    }

    /// Number of uncovered branch regions.
    public var uncoveredBranchCount: Int {
        uncoveredRegions.filter(\.isBranch).count
    }

    /// Number of uncovered non-branch regions (statements).
    public var uncoveredStatementCount: Int {
        uncoveredRegions.filter { !$0.isBranch }.count
    }

    public init(
        functionName: String,
        filename: String,
        uncoveredRegions: [UncoveredRegion],
        coveredRegionCount: Int,
        totalRegionCount: Int
    ) {
        self.functionName = functionName
        self.filename = filename
        self.uncoveredRegions = uncoveredRegions
        self.coveredRegionCount = coveredRegionCount
        self.totalRegionCount = totalRegionCount
    }
}

/// Report of coverage gaps found during fuzzing.
///
/// Only includes functions with partial coverage (some regions hit, some not).
/// Functions with 0% coverage are excluded (likely not the target of the test).
/// Functions with 100% coverage are excluded (no gaps to report).
public struct CoverageGapReport: Sendable {
    /// Functions with partial coverage and their gaps.
    public let gaps: [CoverageGap]

    /// Total functions analyzed (after filtering to project files).
    public let totalFunctionsAnalyzed: Int

    /// Number of functions with 100% coverage.
    public let fullyCoveredFunctionCount: Int

    /// Number of functions with 0% coverage (not counted as gaps).
    public let uncoveredFunctionCount: Int

    /// Whether any gaps were detected.
    public var hasGaps: Bool {
        !gaps.isEmpty
    }

    /// Total number of uncovered regions across all gaps.
    public var totalUncoveredRegions: Int {
        gaps.reduce(0) { $0 + $1.uncoveredRegions.count }
    }

    /// Total number of uncovered branches across all gaps.
    public var totalUncoveredBranches: Int {
        gaps.reduce(0) { $0 + $1.uncoveredBranchCount }
    }

    /// Human-readable summary of the report.
    public var summary: String {
        if gaps.isEmpty {
            return "No coverage gaps detected in \(totalFunctionsAnalyzed) functions (\(fullyCoveredFunctionCount) fully covered)"
        }

        let branchInfo = totalUncoveredBranches > 0
            ? " (\(totalUncoveredBranches) uncovered branches)"
            : ""

        return "Coverage gaps in \(gaps.count) function(s): \(totalUncoveredRegions) uncovered region(s)\(branchInfo)"
    }

    /// Detailed description of all gaps for verbose output.
    public var detailedDescription: String {
        guard hasGaps else { return summary }

        var lines = ["[Fuzz] Coverage gaps detected:"]

        for gap in gaps.sorted(by: { $0.coveragePercentage < $1.coveragePercentage }) {
            let shortFilename = (gap.filename as NSString).lastPathComponent
            lines.append("  - \(gap.functionName) (\(shortFilename)): \(String(format: "%.0f", gap.coveragePercentage))% covered")

            // Group uncovered regions by type
            let branches = gap.uncoveredRegions.filter(\.isBranch)
            let statements = gap.uncoveredRegions.filter { !$0.isBranch }

            for region in branches.prefix(5) {
                if region.lineStart == region.lineEnd {
                    lines.append("    - Line \(region.lineStart): branch not taken")
                } else {
                    lines.append("    - Lines \(region.lineStart)-\(region.lineEnd): branch not taken")
                }
            }

            for region in statements.prefix(5) {
                if region.lineStart == region.lineEnd {
                    lines.append("    - Line \(region.lineStart): not executed")
                } else {
                    lines.append("    - Lines \(region.lineStart)-\(region.lineEnd): not executed")
                }
            }

            let totalShown = min(5, branches.count) + min(5, statements.count)
            let remaining = gap.uncoveredRegions.count - totalShown
            if remaining > 0 {
                lines.append("    - ... and \(remaining) more uncovered region(s)")
            }
        }

        return lines.joined(separator: "\n")
    }

    public init(
        gaps: [CoverageGap],
        totalFunctionsAnalyzed: Int,
        fullyCoveredFunctionCount: Int,
        uncoveredFunctionCount: Int
    ) {
        self.gaps = gaps
        self.totalFunctionsAnalyzed = totalFunctionsAnalyzed
        self.fullyCoveredFunctionCount = fullyCoveredFunctionCount
        self.uncoveredFunctionCount = uncoveredFunctionCount
    }
}

// MARK: - Coverage Gap Detector

/// Detects coverage gaps in partially-covered functions.
///
/// A coverage gap is a function that has some coverage (at least one region executed)
/// but not complete coverage (at least one region not executed). This indicates
/// potential missing test cases or mutation strategies.
///
/// Functions with 0% coverage are excluded because they're likely not the target
/// of the fuzz test. Functions with 100% coverage have no gaps to report.
public struct CoverageGapDetector {

    public init() {}

    /// Detect coverage gaps from resolved coverage data.
    ///
    /// - Parameter coverage: Source-level coverage data from `InMemoryCoverageReader`.
    /// - Returns: A report of all coverage gaps found.
    public func detect(from coverage: ResolvedCoverage) -> CoverageGapReport {
        var gaps: [CoverageGap] = []
        var fullyCoveredCount = 0
        var uncoveredCount = 0

        for function in coverage.functions {
            // Skip functions with no regions
            guard !function.regions.isEmpty else { continue }

            let coveredRegions = function.regions.filter { $0.executionCount > 0 }
            let uncoveredRegions = function.regions.filter { $0.executionCount == 0 }

            let coveredCount = coveredRegions.count
            let totalCount = function.regions.count

            if coveredCount == 0 {
                // 0% coverage - not the target of the test
                uncoveredCount += 1
            } else if coveredCount == totalCount {
                // 100% coverage - no gaps
                fullyCoveredCount += 1
            } else {
                // Partial coverage - this is a gap
                let filename = function.regions.first?.filename ?? "unknown"

                let uncovered = uncoveredRegions.map { region in
                    UncoveredRegion(
                        lineStart: region.lineStart,
                        columnStart: region.columnStart,
                        lineEnd: region.lineEnd,
                        columnEnd: region.columnEnd,
                        isBranch: region.isBranch
                    )
                }

                let gap = CoverageGap(
                    functionName: function.name,
                    filename: filename,
                    uncoveredRegions: uncovered,
                    coveredRegionCount: coveredCount,
                    totalRegionCount: totalCount
                )

                gaps.append(gap)
            }
        }

        return CoverageGapReport(
            gaps: gaps,
            totalFunctionsAnalyzed: coverage.functions.count,
            fullyCoveredFunctionCount: fullyCoveredCount,
            uncoveredFunctionCount: uncoveredCount
        )
    }
}
