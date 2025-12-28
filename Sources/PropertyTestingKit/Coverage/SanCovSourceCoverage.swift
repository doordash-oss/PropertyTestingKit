//
//  SanCovSourceCoverage.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Foundation

/// Coverage result with source-mapped locations (task-isolated).
///
/// When DWARF debug info is available, locations include line numbers,
/// enabling line-level coverage analysis.
public struct SanCovSourceCoverage: Sendable {
    /// All covered source locations.
    public let coveredLocations: [SanCovSourceLocation]

    /// Number of edges covered.
    public var coveredCount: Int { coveredLocations.count }

    /// Whether line numbers are available in the coverage data.
    public var hasLineNumbers: Bool {
        coveredLocations.contains { $0.line != nil }
    }

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

    /// Coverage grouped by file and line (file:line -> locations).
    ///
    /// Only includes locations that have line numbers.
    public var byFileLine: [String: [SanCovSourceLocation]] {
        Dictionary(grouping: coveredLocations.filter { $0.filename != nil && $0.line != nil }) {
            "\($0.filename!):\($0.line!)"
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

    /// Get all unique lines that were covered, grouped by file.
    ///
    /// Returns a dictionary mapping file paths to sets of covered line numbers.
    public var coveredLinesByFile: [String: Set<Int>] {
        var result: [String: Set<Int>] = [:]
        for loc in coveredLocations {
            guard let file = loc.filename, let line = loc.line else { continue }
            result[file, default: []].insert(line)
        }
        return result
    }

    /// Get a summary of covered lines per file.
    ///
    /// Returns formatted strings like "MyFile.swift: lines 10, 15, 20-25"
    public var lineCoverageSummary: [String] {
        coveredLinesByFile.map { (file, lines) in
            let sortedLines = lines.sorted()
            let ranges = collapseToRanges(sortedLines)
            let rangeStr = ranges.map { range in
                range.count == 1 ? "\(range.lowerBound)" : "\(range.lowerBound)-\(range.upperBound)"
            }.joined(separator: ", ")
            return "\(URL(fileURLWithPath: file).lastPathComponent): lines \(rangeStr)"
        }.sorted()
    }
}

/// Collapse consecutive integers into ranges.
private func collapseToRanges(_ sorted: [Int]) -> [ClosedRange<Int>] {
    guard !sorted.isEmpty else { return [] }

    var ranges: [ClosedRange<Int>] = []
    var start = sorted[0]
    var end = sorted[0]

    for i in 1..<sorted.count {
        if sorted[i] == end + 1 {
            end = sorted[i]
        } else {
            ranges.append(start...end)
            start = sorted[i]
            end = sorted[i]
        }
    }
    ranges.append(start...end)
    return ranges
}
