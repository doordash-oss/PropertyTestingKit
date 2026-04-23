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

//  Detects coverage gaps in partially-covered functions.
//

import Foundation

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
        var minCoveragePercentageToReport: Double

        /// Paths to exclude from gap detection (e.g., dependencies, test infrastructure).
        var excludedPathPrefixes: [String]

        /// Whether to only report significant gaps (multiple uncovered regions or low coverage).
        var onlyReportSignificant: Bool

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

    init(config: Config = Config()) {
        self.config = config
    }

    /// Detect coverage gaps from the set of covered edge indices.
    ///
    /// - Parameters:
    ///   - coveredIndices: Set of edge indices that were executed during fuzzing.
    ///   - projectPath: Optional project root path to filter to project files only.
    /// - Returns: A report of detected coverage gaps.
    func detect(from coveredIndices: Set<UInt32>, projectPath: String? = nil) async -> CoverageGapReport {
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

        // Step 1: Get covered edge PCs and do batched DWARF lookup for accurate source paths
        // Key insight: dladdr gives us consistent functionStart addresses, but inconsistent
        // filenames (binary path vs source path from DWARF). Use functionStart as the key.
        var functionEdges: [UInt: FunctionEdgeInfo] = [:]  // Keyed by functionStart
        var testedFunctionStarts: Set<UInt> = []

        // Collect PCs for all covered edges
        var coveredEdgePCs: [(edgeIndex: Int, pc: UInt)] = []
        for edgeIndex in coveredIndices {
            let idx = Int(edgeIndex)
            guard idx < totalEdges else { continue }
            let pc = SanCovCounters.getPC(for: idx)
            if pc > 0 {
                coveredEdgePCs.append((edgeIndex: idx, pc: pc))
            }
        }

        // Batch DWARF lookup for all covered edges (typically small set, ~5-20ms)
        let pcs = coveredEdgePCs.map { $0.pc }
        let dwarfLocations = await SanCovCounters.getDWARFLocations(for: pcs)

        // Process covered edges with DWARF-resolved source paths
        for (edgeIndex, pc) in coveredEdgePCs {
            // Get dladdr info for function start address
            guard let dlAddrLocation = await SanCovCounters.getSourceLocation(for: edgeIndex) else {
                continue
            }

            // functionStart is our key - it's consistent across all dladdr calls within the same function
            let funcStart = dlAddrLocation.functionStart > 0 ? dlAddrLocation.functionStart : pc

            // Use DWARF for filename (accurate source path) and display name
            let dwarfLoc = dwarfLocations[pc]
            let hasDWARF = dwarfLoc != nil
            let filename = dwarfLoc?.file ?? dlAddrLocation.filename
            // Demangle the function name for display (DWARF may return mangled names)
            let rawFuncName = dwarfLoc?.function ?? dlAddrLocation.functionName
            let displayFuncName = rawFuncName.map { demangle($0) }

            guard let filename = filename, let displayFuncName = displayFuncName else {
                continue
            }

            // Skip stdlib functions by name
            if let dlAddrFuncName = dlAddrLocation.functionName, isStdlibFunction(dlAddrFuncName) {
                continue
            }

            // Skip closure thunks and async continuations (mangled names that start with $s
            // and contain patterns like TY0_, TY1_, fU_, etc.)
            if let dlAddrFuncName = dlAddrLocation.functionName, isClosureOrContinuation(dlAddrFuncName) {
                continue
            }

            // Skip excluded paths
            let effectiveProjectPath = hasDWARF ? projectPath : nil
            if shouldExclude(filename: filename, projectPath: effectiveProjectPath) {
                continue
            }

            // Track this function by its start address
            testedFunctionStarts.insert(funcStart)

            var info = functionEdges[funcStart] ?? FunctionEdgeInfo(
                functionName: displayFuncName,
                filename: filename
            )

            info.totalEdges += 1
            info.coveredEdges += 1
            // Track line range from DWARF to filter misattributed uncovered edges
            if let line = dwarfLoc?.line, line > 0 {
                info.minLine = min(info.minLine, line)
                info.maxLine = max(info.maxLine, line)
            }
            functionEdges[funcStart] = info
        }

        // Query symbol table for accurate function sizes (one-time cost)
        // This gives us precise bounds instead of relying on padding
        let functionStartsArray = Array(testedFunctionStarts)
        let functionSizes = SanCovCounters.getFunctionSizes(at: functionStartsArray)

        // Build per-function PC ranges using accurate sizes from symbol table
        // Fallback to 64KB padding if symbol lookup fails
        let fallbackPadding: UInt = 65536

        struct FunctionPCRange {
            let start: UInt
            let end: UInt
        }
        var accurateFunctionRanges: [FunctionPCRange] = []
        accurateFunctionRanges.reserveCapacity(testedFunctionStarts.count)

        var globalMinPC: UInt = .max
        var globalMaxPC: UInt = 0
        for funcStart in testedFunctionStarts {
            let funcEnd: UInt
            if let size = functionSizes[funcStart], size > 0 {
                funcEnd = funcStart + size
            } else {
                // Fallback if symbol table lookup failed
                funcEnd = funcStart + fallbackPadding
            }
            accurateFunctionRanges.append(FunctionPCRange(start: funcStart, end: funcEnd))
            globalMinPC = min(globalMinPC, funcStart)
            globalMaxPC = max(globalMaxPC, funcEnd)
        }

        // If no functions were tested, return early (no gaps to detect)
        if testedFunctionStarts.isEmpty {
            return CoverageGapReport(
                gaps: [],
                totalFunctionsAnalyzed: 0,
                fullyCoveredFunctionCount: 0,
                uncoveredFunctionCount: 0
            )
        }

        // Step 2: Scan uncovered edges, but only for functions we're tracking
        // Use functionStart as the key (consistent across dladdr calls)
        let coveredSet = coveredIndices

        struct UncoveredEdge {
            let edgeIndex: Int
            let pc: UInt
            let funcStart: UInt  // Key for matching
        }
        var uncoveredEdgesNeedingDWARF: [UncoveredEdge] = []

        for edgeIndex in 0..<totalEdges where !coveredSet.contains(UInt32(edgeIndex)) {
            let pc = SanCovCounters.getPC(for: edgeIndex)

            // First filter: Global PC range (very fast)
            if pc < globalMinPC || pc > globalMaxPC {
                continue
            }

            // Second filter: Check if this PC falls within ANY tested function's range
            // and get the matching function start
            var matchingFuncStart: UInt? = nil
            for range in accurateFunctionRanges {
                if pc >= range.start && pc <= range.end {
                    matchingFuncStart = range.start
                    break
                }
            }

            guard let funcStart = matchingFuncStart else {
                continue
            }

            // Verify this function is in our tracked set
            guard testedFunctionStarts.contains(funcStart) else {
                continue
            }

            // Track this edge for batch DWARF lookup
            uncoveredEdgesNeedingDWARF.append(UncoveredEdge(edgeIndex: edgeIndex, pc: pc, funcStart: funcStart))

            // Update total count
            if var info = functionEdges[funcStart] {
                info.totalEdges += 1
                functionEdges[funcStart] = info
            }
        }

        // Second pass: batch DWARF lookup for all uncovered edges to get line numbers
        let uncoveredPCs = uncoveredEdgesNeedingDWARF.map { $0.pc }
        let uncoveredDwarfLocations = await SanCovCounters.getDWARFLocations(for: uncoveredPCs)

        for edge in uncoveredEdgesNeedingDWARF {
            if var info = functionEdges[edge.funcStart] {
                let dwarfLoc = uncoveredDwarfLocations[edge.pc]
                let line = dwarfLoc?.line ?? 0

                // Filter out edges without DWARF info or outside the function's line range.
                // PC range matching can be imprecise - DWARF line numbers are authoritative.
                // Without DWARF, we can't verify the edge belongs to this function.
                let hasValidLineRange = info.minLine <= info.maxLine
                if hasValidLineRange {
                    if line == 0 || line < info.minLine || line > info.maxLine {
                        // No DWARF info or line outside function - don't count it
                        info.totalEdges -= 1  // Undo the increment from earlier
                        functionEdges[edge.funcStart] = info
                        continue
                    }
                }

                info.uncoveredEdges.append(EdgeInfo(
                    index: edge.edgeIndex,
                    pc: edge.pc,
                    line: line,
                    column: dwarfLoc?.column ?? 0,
                    filePath: dwarfLoc?.file
                ))
                functionEdges[edge.funcStart] = info
            }
        }

        // Analyze each function and detect gaps
        var gaps: [CoverageGap] = []
        var fullyCoveredCount = 0
        var uncoveredCount = 0

        for (_, info) in functionEdges {
            // Skip closure thunks and async continuations at reporting time
            // (they might slip through if a different edge was used to register the function)
            if isClosureOrContinuation(info.functionName) || isStdlibFunction(info.functionName) {
                continue
            }

            // Skip functions without DWARF line info - we can't accurately determine edges
            // without line filtering, which would lead to incorrect coverage percentages
            let hasValidLineRange = info.minLine <= info.maxLine
            if !hasValidLineRange {
                continue
            }

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
                        isBranch: false,  // TODO: detect branches vs statements
                        filePath: edge.filePath
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
        // (DWARF lookup provides accurate source paths, so this filter works correctly)
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
    // Track source line range from covered edges to filter misattributed uncovered edges
    var minLine: Int = Int.max
    var maxLine: Int = 0
}

private struct EdgeInfo {
    let index: Int
    let pc: UInt
    let line: Int
    let column: Int
    let filePath: String?
}

/// Check if a function name represents a closure, thunk, or async continuation.
/// These are compiler-generated and shouldn't be reported as separate coverage gaps.
fileprivate func isClosureOrContinuation(_ functionName: String) -> Bool {
    // Mangled Swift names for async continuations (TY0_, TY1_, etc.)
    // These are compiler-generated suspend/resume points
    if functionName.contains("TY0_") || functionName.contains("TY1_") ||
        functionName.contains("TY2_") || functionName.contains("TY3_") {
        return true
    }

    // Demangled async continuation names
    if functionName.contains("suspend resume partial function") ||
        functionName.contains("await resume partial function") {
        return true
    }

    // Closure thunks (fU_, fU0_, etc.) - but only if they're mangled (start with $s)
    // We want to keep named closures like "partiallyCoveredFunction #1" but skip
    // anonymous closure thunks
    if functionName.hasPrefix("$s") && (
        functionName.contains("fU_") ||
        functionName.contains("fU0_") ||
        functionName.contains("fU1_")
    ) {
        return true
    }

    return false
}
