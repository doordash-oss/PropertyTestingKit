//
//  LLVMCoverageReader.swift
//  PropertyTestingKit
//
//  Swift interface to LLVM's coverage library via C++ interop.
//

import Foundation
import LLVMCoverageInterop

// MARK: - LLVMCoverageReader

/// Direct interface to LLVM's coverage library.
///
/// This provides in-memory access to coverage data without spawning
/// external processes. Requires LLVM to be installed (e.g., via Homebrew).
///
/// ## Usage
///
/// ```swift
/// // Load coverage from a binary and profdata file
/// let reader = try LLVMCoverageReader.load(
///     objectPath: "/path/to/binary",
///     profilePath: "/path/to/coverage.profdata"
/// )
///
/// // Get list of source files
/// let files = reader.sourceFiles
///
/// // Get coverage for a specific file
/// let fileCoverage = reader.coverage(for: "MyFile.swift")
/// print("Covered: \(fileCoverage.coveredLines)/\(fileCoverage.totalLines)")
///
/// // Check if a specific line was executed
/// if reader.isLineCovered(file: "MyFile.swift", line: 42) {
///     print("Line 42 was executed")
/// }
/// ```
public final class LLVMCoverageReader: @unchecked Sendable {
    private let reader: ptk.CoverageReader

    private init(_ reader: ptk.CoverageReader) {
        self.reader = reader
    }

    deinit {
        // The reader is immortal (managed by us), so we need to destroy it
        ptk.CoverageReader.destroy(reader)
    }

    /// Load coverage data from a binary and profile file.
    ///
    /// - Parameters:
    ///   - objectPath: Path to the instrumented binary.
    ///   - profilePath: Path to the merged .profdata file.
    /// - Returns: A coverage reader for querying the data.
    /// - Throws: ``LLVMCoverageError`` if loading fails.
    public static func load(
        objectPath: String,
        profilePath: String
    ) throws -> LLVMCoverageReader {
        var error = ptk.CoverageError.none()

        guard let reader = ptk.CoverageReader.load(
            std.string(objectPath),
            std.string(profilePath),
            &error
        ) else {
            if error.hasError {
                throw LLVMCoverageError.loadFailed(String(error.message))
            }
            throw LLVMCoverageError.loadFailed("Unknown error loading coverage")
        }

        if error.hasError {
            throw LLVMCoverageError.loadFailed(String(error.message))
        }

        return LLVMCoverageReader(reader)
    }

    /// List of all source files with coverage data.
    public var sourceFiles: [String] {
        let files = reader.getSourceFiles()
        return files.map { String($0) }
    }

    /// Get coverage information for a specific file.
    ///
    /// - Parameter filename: The source file path.
    /// - Returns: Coverage statistics for the file.
    public func coverage(for filename: String) -> FileCoverageInfo {
        let cov = reader.getFileCoverage(std.string(filename))
        return FileCoverageInfo(cov)
    }

    /// Get overall coverage summary.
    public var summary: CoverageSummaryInfo {
        let sum = reader.getSummary()
        return CoverageSummaryInfo(sum)
    }

    /// Get the execution count for a specific line.
    ///
    /// - Parameters:
    ///   - file: The source file path.
    ///   - line: The line number (1-indexed).
    /// - Returns: Number of times the line was executed, or 0 if not covered.
    public func executionCount(file: String, line: UInt32) -> UInt64 {
        return reader.getLineExecutionCount(std.string(file), line)
    }

    /// Check if a specific line was executed at least once.
    ///
    /// - Parameters:
    ///   - file: The source file path.
    ///   - line: The line number (1-indexed).
    /// - Returns: `true` if the line was executed.
    public func isLineCovered(file: String, line: UInt32) -> Bool {
        return reader.isLineCovered(std.string(file), line)
    }
}

// MARK: - Supporting Types

/// Coverage information for a single file.
public struct FileCoverageInfo: Sendable {
    /// The filename.
    public let filename: String

    /// Line-by-line coverage data.
    public let lines: [LineCoverageInfo]

    /// Number of lines that were executed at least once.
    public let coveredLines: UInt64

    /// Total number of executable lines.
    public let totalLines: UInt64

    /// Coverage percentage (0.0 to 1.0).
    public var percentage: Double {
        guard totalLines > 0 else { return 0 }
        return Double(coveredLines) / Double(totalLines)
    }

    init(_ cov: ptk.FileCoverage) {
        self.filename = String(cov.filename)
        self.coveredLines = cov.coveredLines
        self.totalLines = cov.totalLines
        self.lines = cov.lines.map { LineCoverageInfo($0) }
    }
}

/// Coverage information for a single line.
public struct LineCoverageInfo: Sendable {
    /// The line number (1-indexed).
    public let line: UInt32

    /// Number of times this line was executed.
    public let executionCount: UInt64

    /// Whether this line contains executable code.
    public let isMapped: Bool

    /// Whether this line has multiple coverage regions.
    public let hasMultipleRegions: Bool

    /// Whether this line was executed at least once.
    public var isCovered: Bool {
        return executionCount > 0
    }

    init(_ lc: ptk.LineCoverage) {
        self.line = lc.line
        self.executionCount = lc.executionCount
        self.isMapped = lc.isMapped
        self.hasMultipleRegions = lc.hasMultipleRegions
    }
}

/// Overall coverage summary.
public struct CoverageSummaryInfo: Sendable {
    /// Total number of functions.
    public let totalFunctions: UInt64

    /// Number of functions with at least one executed region.
    public let coveredFunctions: UInt64

    /// Total number of executable lines.
    public let totalLines: UInt64

    /// Number of lines executed at least once.
    public let coveredLines: UInt64

    /// Total number of code regions.
    public let totalRegions: UInt64

    /// Number of regions executed at least once.
    public let coveredRegions: UInt64

    /// Function coverage percentage.
    public var functionPercentage: Double {
        guard totalFunctions > 0 else { return 0 }
        return Double(coveredFunctions) / Double(totalFunctions)
    }

    /// Line coverage percentage.
    public var linePercentage: Double {
        guard totalLines > 0 else { return 0 }
        return Double(coveredLines) / Double(totalLines)
    }

    /// Region coverage percentage.
    public var regionPercentage: Double {
        guard totalRegions > 0 else { return 0 }
        return Double(coveredRegions) / Double(totalRegions)
    }

    init(_ sum: ptk.CoverageSummary) {
        self.totalFunctions = sum.totalFunctions
        self.coveredFunctions = sum.coveredFunctions
        self.totalLines = sum.totalLines
        self.coveredLines = sum.coveredLines
        self.totalRegions = sum.totalRegions
        self.coveredRegions = sum.coveredRegions
    }
}

// MARK: - Errors

/// Errors from LLVM coverage operations.
public enum LLVMCoverageError: Error, CustomStringConvertible {
    /// Failed to load coverage data.
    case loadFailed(String)

    public var description: String {
        switch self {
        case .loadFailed(let message):
            return "Failed to load coverage: \(message)"
        }
    }
}
