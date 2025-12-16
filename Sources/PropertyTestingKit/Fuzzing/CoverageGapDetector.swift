//
//  CoverageGapDetector.swift
//  PropertyTestingKit
//
//  Detects coverage gaps in partially-covered functions.
//

import Foundation

// MARK: - Coverage Gap Types

/// An uncovered region within a function.
public struct UncoveredRegion: Sendable, Equatable {
    /// The starting line number (1-indexed).
    public let lineStart: Int

    /// The starting column number (1-indexed).
    public let columnStart: Int

    /// The ending line number (1-indexed).
    public let lineEnd: Int

    /// The ending column number (1-indexed).
    public let columnEnd: Int

    /// The edge index in the SanCov PC table.
    public let edgeIndex: Int

    /// Whether this region represents a branch (vs a statement).
    public let isBranch: Bool

    public init(
        lineStart: Int,
        columnStart: Int,
        lineEnd: Int = 0,
        columnEnd: Int = 0,
        edgeIndex: Int,
        isBranch: Bool = false
    ) {
        self.lineStart = lineStart
        self.columnStart = columnStart
        self.lineEnd = lineEnd > 0 ? lineEnd : lineStart
        self.columnEnd = columnEnd > 0 ? columnEnd : columnStart
        self.edgeIndex = edgeIndex
        self.isBranch = isBranch
    }
}

/// A coverage gap in a partially-covered function.
public struct CoverageGap: Sendable, Equatable {
    /// The function name containing the gap.
    public let functionName: String

    /// Source file path.
    public let filename: String

    /// Uncovered regions within this function.
    public let uncoveredRegions: [UncoveredRegion]

    /// Number of covered edges in this function.
    public let coveredEdgeCount: Int

    /// Total number of edges in this function.
    public let totalEdgeCount: Int

    /// Coverage percentage for this function.
    public var coveragePercentage: Double {
        totalEdgeCount > 0 ? Double(coveredEdgeCount) / Double(totalEdgeCount) * 100 : 0
    }

    /// Whether this gap is significant (more than one uncovered edge).
    public var isSignificant: Bool {
        uncoveredRegions.count > 1 || (totalEdgeCount > 2 && coveragePercentage < 90)
    }

    public init(
        functionName: String,
        filename: String,
        uncoveredRegions: [UncoveredRegion],
        coveredEdgeCount: Int,
        totalEdgeCount: Int
    ) {
        self.functionName = functionName
        self.filename = filename
        self.uncoveredRegions = uncoveredRegions
        self.coveredEdgeCount = coveredEdgeCount
        self.totalEdgeCount = totalEdgeCount
    }
}

/// Report of all coverage gaps found during fuzzing.
public struct CoverageGapReport: Sendable, Equatable {
    /// Functions with partial coverage (some edges hit, some not).
    public let gaps: [CoverageGap]

    /// Total functions analyzed.
    public let totalFunctionsAnalyzed: Int

    /// Functions with complete coverage (100%).
    public let fullyCoveredFunctionCount: Int

    /// Functions with no coverage (0%).
    public let uncoveredFunctionCount: Int

    /// Whether any significant gaps were found.
    public var hasSignificantGaps: Bool {
        gaps.contains { $0.isSignificant }
    }

    /// Summary for display.
    public var summary: String {
        if gaps.isEmpty {
            return "No coverage gaps detected in \(totalFunctionsAnalyzed) functions"
        }

        let significantCount = gaps.filter { $0.isSignificant }.count
        var result = "Coverage gaps in \(gaps.count) function(s)"
        if significantCount > 0 && significantCount < gaps.count {
            result += " (\(significantCount) significant)"
        }
        return result
    }

    /// Detailed report for verbose output.
    public var detailedSummary: String {
        guard !gaps.isEmpty else {
            return summary
        }

        var lines = [summary]

        for gap in gaps.sorted(by: { $0.coveragePercentage < $1.coveragePercentage }) {
            let file = URL(fileURLWithPath: gap.filename).lastPathComponent
            let pct = String(format: "%.0f", gap.coveragePercentage)
            lines.append("  - \(gap.functionName) (\(file)): \(pct)% covered, \(gap.uncoveredRegions.count) uncovered region(s)")

            // Show first few uncovered regions
            for region in gap.uncoveredRegions.prefix(3) {
                if region.lineStart > 0 {
                    let desc = region.isBranch ? "branch not taken" : "not executed"
                    lines.append("    - Line \(region.lineStart): \(desc)")
                }
            }
            if gap.uncoveredRegions.count > 3 {
                lines.append("    - ... and \(gap.uncoveredRegions.count - 3) more")
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
/// A "gap" is defined as a function where some edges were executed but others weren't.
/// Functions with 0% coverage are excluded (they're likely not the target of the test).
/// Functions with 100% coverage have no gaps.
///
/// Usage:
/// ```swift
/// let detector = CoverageGapDetector()
/// let report = detector.detect(from: coveredIndices)
/// print(report.detailedSummary)
/// ```
public struct CoverageGapDetector: Sendable {
    /// Configuration for gap detection.
    public struct Config: Sendable {
        /// Minimum coverage percentage to report as a gap.
        /// Functions below this threshold are considered "uncovered" rather than "partially covered".
        public var minCoveragePercentageToReport: Double

        /// Paths to exclude from gap detection (e.g., dependencies, test infrastructure).
        public var excludedPathPrefixes: [String]

        /// Whether to only report significant gaps (multiple uncovered regions or low coverage).
        public var onlyReportSignificant: Bool

        public init(
            minCoveragePercentageToReport: Double = 5.0,
            excludedPathPrefixes: [String] = [],
            onlyReportSignificant: Bool = true
        ) {
            self.minCoveragePercentageToReport = minCoveragePercentageToReport
            self.excludedPathPrefixes = excludedPathPrefixes
            self.onlyReportSignificant = onlyReportSignificant
        }
    }

    private let config: Config

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Detect coverage gaps from the set of covered edge indices.
    ///
    /// - Parameters:
    ///   - coveredIndices: Set of edge indices that were executed during fuzzing.
    ///   - projectPath: Optional project root path to filter to project files only.
    /// - Returns: A report of detected coverage gaps.
    public func detect(from coveredIndices: Set<Int>, projectPath: String? = nil) -> CoverageGapReport {
        guard SanCovCounters.isAvailable else {
            return CoverageGapReport(
                gaps: [],
                totalFunctionsAnalyzed: 0,
                fullyCoveredFunctionCount: 0,
                uncoveredFunctionCount: 0
            )
        }

        let totalEdges = SanCovCounters.totalEdgeCount
        guard totalEdges > 0 else {
            return CoverageGapReport(
                gaps: [],
                totalFunctionsAnalyzed: 0,
                fullyCoveredFunctionCount: 0,
                uncoveredFunctionCount: 0
            )
        }

        // Group all edges by function
        var functionEdges: [String: FunctionEdgeInfo] = [:]

        for edgeIndex in 0..<totalEdges {
            guard let location = SanCovCounters.getSourceLocation(for: edgeIndex) else {
                continue
            }

            // Skip edges without function names
            guard let funcName = location.functionName,
                  let filename = location.filename else {
                continue
            }

            // Skip excluded paths
            if shouldExclude(filename: filename, projectPath: projectPath) {
                continue
            }

            let key = "\(filename):\(funcName)"
            var info = functionEdges[key] ?? FunctionEdgeInfo(
                functionName: funcName,
                filename: filename
            )

            let isCovered = coveredIndices.contains(edgeIndex)
            info.totalEdges += 1
            if isCovered {
                info.coveredEdges += 1
            } else {
                info.uncoveredEdges.append(EdgeInfo(
                    index: edgeIndex,
                    line: location.line ?? 0,
                    column: location.column ?? 0
                ))
            }

            functionEdges[key] = info
        }

        // Analyze each function and detect gaps
        var gaps: [CoverageGap] = []
        var fullyCoveredCount = 0
        var uncoveredCount = 0

        for (_, info) in functionEdges {
            let coveragePct = info.totalEdges > 0
                ? Double(info.coveredEdges) / Double(info.totalEdges) * 100
                : 0

            if coveragePct >= 100 {
                fullyCoveredCount += 1
            } else if coveragePct < config.minCoveragePercentageToReport {
                uncoveredCount += 1
            } else {
                // Partial coverage - this is a gap
                let uncoveredRegions = info.uncoveredEdges.map { edge in
                    UncoveredRegion(
                        lineStart: edge.line,
                        columnStart: edge.column,
                        edgeIndex: edge.index,
                        isBranch: false  // TODO: detect branches vs statements
                    )
                }

                let gap = CoverageGap(
                    functionName: info.functionName,
                    filename: info.filename,
                    uncoveredRegions: uncoveredRegions,
                    coveredEdgeCount: info.coveredEdges,
                    totalEdgeCount: info.totalEdges
                )

                if !config.onlyReportSignificant || gap.isSignificant {
                    gaps.append(gap)
                }
            }
        }

        return CoverageGapReport(
            gaps: gaps.sorted { $0.coveragePercentage < $1.coveragePercentage },
            totalFunctionsAnalyzed: functionEdges.count,
            fullyCoveredFunctionCount: fullyCoveredCount,
            uncoveredFunctionCount: uncoveredCount
        )
    }

    /// Check if a filename should be excluded from gap detection.
    private func shouldExclude(filename: String, projectPath: String?) -> Bool {
        // Always exclude system and build paths
        let systemPrefixes = [
            "/usr/",
            "/System/",
            "/Library/",
            ".build/checkouts/",
            ".build/repositories/",
            "SourcePackages/checkouts/",
            "/Applications/Xcode"
        ]

        for prefix in systemPrefixes {
            if filename.contains(prefix) {
                return true
            }
        }

        // Exclude configured prefixes
        for prefix in config.excludedPathPrefixes {
            if filename.hasPrefix(prefix) || filename.contains(prefix) {
                return true
            }
        }

        // If project path is specified, only include files in the project
        if let projectPath = projectPath {
            if !filename.hasPrefix(projectPath) {
                return true
            }
        }

        return false
    }
}

// MARK: - Helper Types

private struct FunctionEdgeInfo {
    let functionName: String
    let filename: String
    var totalEdges: Int = 0
    var coveredEdges: Int = 0
    var uncoveredEdges: [EdgeInfo] = []
}

private struct EdgeInfo {
    let index: Int
    let line: Int
    let column: Int
}
