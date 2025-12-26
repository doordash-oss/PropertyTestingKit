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
    /// The starting line number (1-indexed). May be 0 if not yet resolved.
    public let lineStart: Int

    /// The starting column number (1-indexed). May be 0 if not yet resolved.
    public let columnStart: Int

    /// The ending line number (1-indexed).
    public let lineEnd: Int

    /// The ending column number (1-indexed).
    public let columnEnd: Int

    /// The edge index in the SanCov PC table.
    public let edgeIndex: Int

    /// The program counter for this edge (for lazy line lookup).
    public let pc: UInt

    /// Whether this region represents a branch (vs a statement).
    public let isBranch: Bool

    public init(
        lineStart: Int,
        columnStart: Int,
        lineEnd: Int = 0,
        columnEnd: Int = 0,
        edgeIndex: Int,
        pc: UInt = 0,
        isBranch: Bool = false
    ) {
        self.lineStart = lineStart
        self.columnStart = columnStart
        self.lineEnd = lineEnd > 0 ? lineEnd : lineStart
        self.columnEnd = columnEnd > 0 ? columnEnd : columnStart
        self.edgeIndex = edgeIndex
        self.pc = pc
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
/// let report = await detector.detect(from: coveredIndices)
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
    public func detect(from coveredIndices: Set<Int>, projectPath: String? = nil) async -> CoverageGapReport {
        #if DEBUG
        SanCovCounters.resetDlAddrCallCount()
        #endif

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

        // Optimization: Use fast dladdr lookups (no DWARF) for initial function detection,
        // then only use expensive DWARF lookups for uncovered edges that need line numbers.

        // Step 1: Fast scan to find all function keys and count edges (no DWARF)
        // Also track PC ranges for each function to enable fast filtering in Step 2
        // let step1Start = CFAbsoluteTimeGetCurrent()
        var functionEdges: [String: FunctionEdgeInfo] = [:]
        var testedFunctions: Set<String> = []
        var functionPCRanges: [String: (min: UInt, max: UInt)] = [:]

        // Mark functions that have covered edges as "tested"
        for edgeIndex in coveredIndices {
            guard edgeIndex < totalEdges else { continue }
            guard let location = SanCovCounters.getSourceLocationSync(for: edgeIndex) else {
                continue
            }

            guard let funcName = location.functionName,
                  let filename = location.filename else {
                continue
            }

            // Skip excluded paths
            if shouldExclude(filename: filename, projectPath: projectPath) {
                continue
            }

            let key = "\(filename):\(funcName)"
            testedFunctions.insert(key)

            // Track function start address from dladdr (true function start)
            let funcStart = location.functionStart > 0 ? location.functionStart : location.pc
            if let existing = functionPCRanges[key] {
                // Use minimum of all function starts we've seen (should be the same)
                functionPCRanges[key] = (min: min(existing.min, funcStart), max: existing.max)
            } else {
                functionPCRanges[key] = (min: funcStart, max: 0)  // max will be set from symbol table
            }

            var info = functionEdges[key] ?? FunctionEdgeInfo(
                functionName: funcName,
                filename: filename
            )

            info.totalEdges += 1
            info.coveredEdges += 1
            functionEdges[key] = info
        }

        // Query symbol table for accurate function sizes (one-time cost)
        // This gives us precise bounds instead of relying on padding
        let functionStarts = Array(Set(functionPCRanges.values.map { $0.min }))
        let functionSizes = await SanCovCounters.getFunctionSizes(at: functionStarts)

        // #if DEBUG
        // let symbolTableTime = CFAbsoluteTimeGetCurrent()
        // print("[GapDetector] Symbol table lookup: \(String(format: "%.3f", symbolTableTime - step1Start))s for \(functionStarts.count) functions")
        // #endif

        // Build per-function PC ranges using accurate sizes from symbol table
        // Fallback to 64KB padding if symbol lookup fails
        let fallbackPadding: UInt = 65536

        struct FunctionPCRange {
            let min: UInt
            let max: UInt
        }
        var accurateFunctionRanges: [FunctionPCRange] = []
        accurateFunctionRanges.reserveCapacity(functionPCRanges.count)

        var globalMinPC: UInt = .max
        var globalMaxPC: UInt = 0
        for (_, range) in functionPCRanges {
            let funcStart = range.min
            let funcEnd: UInt
            if let size = functionSizes[funcStart], size > 0 {
                funcEnd = funcStart + size
            } else {
                // Fallback if symbol table lookup failed
                funcEnd = funcStart + fallbackPadding
            }
            accurateFunctionRanges.append(FunctionPCRange(min: funcStart, max: funcEnd))
            globalMinPC = min(globalMinPC, funcStart)
            globalMaxPC = max(globalMaxPC, funcEnd)
        }

        // let step1End = CFAbsoluteTimeGetCurrent()

        // If no functions were tested, return early (no gaps to detect)
        if testedFunctions.isEmpty {
            return CoverageGapReport(
                gaps: [],
                totalFunctionsAnalyzed: 0,
                fullyCoveredFunctionCount: 0,
                uncoveredFunctionCount: 0
            )
        }

        // let step2Start = CFAbsoluteTimeGetCurrent()
        // Step 2: Scan uncovered edges, but only for functions we're tracking
        // Optimization: First filter by PC range (fast array lookup), then dladdr only for candidates
        // Collect all edges that need DWARF lookup, then batch process them
        let coveredSet = coveredIndices

        // First pass: identify uncovered edges in tested functions (no DWARF)
        struct UncoveredEdge {
            let edgeIndex: Int
            let pc: UInt
            let key: String
        }
        var uncoveredEdgesNeedingDWARF: [UncoveredEdge] = []

        // #if DEBUG
        // var step2PCFilterTime: Double = 0
        // var step2DladdrTime: Double = 0
        // var step2FunctionFilterTime: Double = 0
        // var step2EdgesPCFiltered: Int = 0
        // var step2EdgesDladdrd: Int = 0
        // var step2EdgesFunctionFiltered: Int = 0
        // #endif

        for edgeIndex in 0..<totalEdges where !coveredSet.contains(edgeIndex) {
            // Fast PC range filter - skip edges clearly outside tested functions
            // #if DEBUG
            // let pcStart = CFAbsoluteTimeGetCurrent()
            // #endif
            let pc = SanCovCounters.getPC(for: edgeIndex)

            // First filter: Global PC range (very fast)
            if pc < globalMinPC || pc > globalMaxPC {
                // #if DEBUG
                // step2PCFilterTime += CFAbsoluteTimeGetCurrent() - pcStart
                // step2EdgesPCFiltered += 1
                // #endif
                continue
            }

            // Second filter: Per-function PC ranges (using accurate sizes from symbol table)
            // Check if this PC falls within ANY tested function's range
            var inAnyFunctionRange = false
            for range in accurateFunctionRanges {
                if pc >= range.min && pc <= range.max {
                    inAnyFunctionRange = true
                    break
                }
            }

            if !inAnyFunctionRange {
                // #if DEBUG
                // step2PCFilterTime += CFAbsoluteTimeGetCurrent() - pcStart
                // step2EdgesPCFiltered += 1
                // #endif
                continue
            }
            // #if DEBUG
            // step2PCFilterTime += CFAbsoluteTimeGetCurrent() - pcStart
            // #endif

            // Only now do the expensive dladdr call
            // #if DEBUG
            // let dladdrStart = CFAbsoluteTimeGetCurrent()
            // #endif
            guard let location = SanCovCounters.getSourceLocationSync(for: edgeIndex) else {
                // #if DEBUG
                // step2DladdrTime += CFAbsoluteTimeGetCurrent() - dladdrStart
                // step2EdgesDladdrd += 1
                // #endif
                continue
            }
            // #if DEBUG
            // step2DladdrTime += CFAbsoluteTimeGetCurrent() - dladdrStart
            // step2EdgesDladdrd += 1
            // #endif

            guard let funcName = location.functionName,
                  let filename = location.filename else {
                continue
            }

            // #if DEBUG
            // let funcFilterStart = CFAbsoluteTimeGetCurrent()
            // #endif
            let key = "\(filename):\(funcName)"

            // Only track uncovered edges from tested functions
            guard testedFunctions.contains(key) else {
                // #if DEBUG
                // step2FunctionFilterTime += CFAbsoluteTimeGetCurrent() - funcFilterStart
                // step2EdgesFunctionFiltered += 1
                // #endif
                continue
            }
            // #if DEBUG
            // step2FunctionFilterTime += CFAbsoluteTimeGetCurrent() - funcFilterStart
            // #endif

            // Track this edge for batch DWARF lookup
            uncoveredEdgesNeedingDWARF.append(UncoveredEdge(edgeIndex: edgeIndex, pc: pc, key: key))

            // Update total count (we don't have line info yet)
            if var info = functionEdges[key] {
                info.totalEdges += 1
                functionEdges[key] = info
            }
        }

        // let step2FirstPassEnd = CFAbsoluteTimeGetCurrent()

        // Second pass: batch DWARF lookup for all uncovered edges
        // Optimization: Skip DWARF lookup during detection. Line numbers are computed
        // lazily when detailedSummary is accessed (if ever). This saves ~10-20ms.
        for edge in uncoveredEdgesNeedingDWARF {
            if var info = functionEdges[edge.key] {
                // Store edge index and PC, defer line lookup to lazy access
                info.uncoveredEdges.append(EdgeInfo(
                    index: edge.edgeIndex,
                    pc: edge.pc,
                    line: 0,  // Will be computed lazily if needed
                    column: 0
                ))
                functionEdges[edge.key] = info
            }
        }

        // #if DEBUG
        // print("[GapDetector] Step 1 (covered edges dladdr): \(String(format: "%.3f", step1End - step1Start))s")
        // print("[GapDetector] Step 2 total: \(String(format: "%.3f", step2FirstPassEnd - step2Start))s")
        // print("[GapDetector]   - PC filter time: \(String(format: "%.3f", step2PCFilterTime))s (\(step2EdgesPCFiltered) edges filtered out)")
        // print("[GapDetector]   - dladdr time: \(String(format: "%.3f", step2DladdrTime))s (\(step2EdgesDladdrd) calls)")
        // print("[GapDetector]   - Function filter time: \(String(format: "%.3f", step2FunctionFilterTime))s (\(step2EdgesFunctionFiltered) edges filtered out)")
        // print("[GapDetector] Edges scanned: \(totalEdges), uncovered edges in report: \(uncoveredEdgesNeedingDWARF.count)")
        // print("[GapDetector] Total dladdr calls: \(SanCovCounters.dlAddrCallCount)")
        // #endif

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
                        pc: edge.pc,
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

                // Always include gaps - significance filtering happens at reporting time
                gaps.append(gap)
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
        // Note: Be careful with "/Library/" - user Library paths like
        // "/Users/alex/Library/Developer" should NOT be excluded
        let systemPrefixes = [
            "/usr/lib/",
            "/usr/share/",
            "/System/",
            "/Library/Frameworks/",
            "/Library/Developer/",  // System-wide developer tools
            ".build/checkouts/",
            ".build/repositories/",
            "SourcePackages/checkouts/",
            "/Applications/Xcode"
        ]

        for prefix in systemPrefixes {
            if filename.contains(prefix) {
                // Exception: Don't exclude user-specific Library paths
                // e.g., /Users/alex/Library/Developer/Xcode/DerivedData
                if prefix == "/Library/Developer/" && filename.contains("/Users/") {
                    continue
                }
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
    let pc: UInt
    let line: Int
    let column: Int
}
