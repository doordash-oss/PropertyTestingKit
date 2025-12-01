//
//  InMemoryCoverageReader.swift
//  PropertyTestingKit
//
//  Swift interface for in-memory coverage resolution.
//  This bypasses the profraw → profdata pipeline entirely.
//

import Foundation
import LLVMCoverageInterop
import PropertyTestingKitInternals

// MARK: - InMemoryCoverageReader

/// Reader that parses coverage mapping from a binary and resolves
/// execution counts directly from in-memory counters.
///
/// This avoids the profraw → profdata file I/O pipeline entirely,
/// enabling instant coverage queries.
///
/// ## Usage
///
/// ```swift
/// // Load coverage mapping (one-time, can be cached)
/// let reader = try InMemoryCoverageReader.loadFromCurrentProcess()
///
/// // Query coverage with current in-memory counters
/// let coverage = reader.resolveCoverage()
///
/// // Inspect source-level coverage
/// for func in coverage.functions {
///     print("\(func.name): \(func.executionCount) executions")
///     for region in func.regions {
///         print("  \(region.filename):\(region.lineStart) - \(region.executionCount)x")
///     }
/// }
/// ```
public final class InMemoryCoverageReader: @unchecked Sendable {
    private let reader: ptk.InMemoryCoverageReader

    private init(_ reader: ptk.InMemoryCoverageReader) {
        self.reader = reader
    }

    deinit {
        ptk.InMemoryCoverageReader.destroy(reader)
    }

    /// Load coverage mapping from the current process's binary.
    ///
    /// This parses the `__llvm_covmap` and `__llvm_covfun` sections
    /// from the executable. This is a one-time operation that can
    /// be cached for repeated queries.
    ///
    /// - Returns: A reader for resolving coverage.
    /// - Throws: ``InMemoryCoverageError`` if loading fails.
    public static func loadFromCurrentProcess() throws -> InMemoryCoverageReader {
        var error = ptk.CoverageError.none()

        guard let reader = ptk.InMemoryCoverageReader.loadFromCurrentProcess(&error) else {
            if error.hasError {
                throw InMemoryCoverageError.loadFailed(String(error.message))
            }
            throw InMemoryCoverageError.loadFailed("Unknown error loading coverage mapping")
        }

        if error.hasError {
            throw InMemoryCoverageError.loadFailed(String(error.message))
        }

        return InMemoryCoverageReader(reader)
    }

    /// Load coverage mapping from a specific binary.
    ///
    /// - Parameter binaryPath: Path to the instrumented binary.
    /// - Returns: A reader for resolving coverage.
    /// - Throws: ``InMemoryCoverageError`` if loading fails.
    public static func loadFromBinary(_ binaryPath: String) throws -> InMemoryCoverageReader {
        var error = ptk.CoverageError.none()

        guard let reader = ptk.InMemoryCoverageReader.loadFromBinary(
            std.string(binaryPath),
            &error
        ) else {
            if error.hasError {
                throw InMemoryCoverageError.loadFailed(String(error.message))
            }
            throw InMemoryCoverageError.loadFailed("Unknown error loading coverage mapping")
        }

        if error.hasError {
            throw InMemoryCoverageError.loadFailed(String(error.message))
        }

        return InMemoryCoverageReader(reader)
    }

    /// Resolve coverage using current in-memory counter values.
    ///
    /// This reads the current counter values directly from memory
    /// and resolves them to source-level coverage data.
    ///
    /// - Returns: Coverage data with resolved execution counts.
    public func resolveCoverage() -> ResolvedCoverage {
        guard CoverageTrait.isAvailable else {
            return ResolvedCoverage(functions: [], sourceFiles: [])
        }

        let begin = __llvm_profile_begin_counters()
        let end = __llvm_profile_end_counters()

        guard let begin = begin, let end = end else {
            return ResolvedCoverage(functions: [], sourceFiles: [])
        }

        let count = end - begin
        guard count > 0 else {
            return ResolvedCoverage(functions: [], sourceFiles: [])
        }

        let data = reader.resolveCoverage(begin, count)
        return ResolvedCoverage(data)
    }

    /// Resolve coverage using provided counter values.
    ///
    /// Use this for isolated coverage measurement by providing
    /// a specific set of counter values.
    ///
    /// - Parameter counters: Counter values to resolve.
    /// - Returns: Coverage data with resolved execution counts.
    public func resolveCoverage(counters: [UInt64]) -> ResolvedCoverage {
        let data = counters.withUnsafeBufferPointer { buffer in
            reader.resolveCoverage(buffer.baseAddress, buffer.count)
        }
        return ResolvedCoverage(data)
    }

    /// Get the list of source files from the coverage mapping.
    public var sourceFiles: [String] {
        reader.getSourceFiles().map { String($0) }
    }

    /// Get the number of functions in the coverage mapping.
    public var functionCount: Int {
        Int(reader.getFunctionCount())
    }
}

// MARK: - Resolved Coverage Data

/// Coverage data resolved from in-memory counters.
public struct ResolvedCoverage: Sendable {
    /// Coverage information for all functions.
    public let functions: [ResolvedFunctionCoverage]

    /// List of all source files with coverage data.
    public let sourceFiles: [String]

    init(functions: [ResolvedFunctionCoverage], sourceFiles: [String]) {
        self.functions = functions
        self.sourceFiles = sourceFiles
    }

    init(_ data: ptk.InMemoryCoverageData) {
        self.functions = data.functions.map { ResolvedFunctionCoverage($0) }
        self.sourceFiles = data.sourceFiles.map { String($0) }
    }

    /// Get coverage for a specific file.
    public func coverage(for filename: String) -> [ResolvedRegionCoverage] {
        functions.flatMap { func_ in
            func_.regions.filter { $0.filename == filename || $0.filename.hasSuffix("/\(filename)") }
        }
    }

    /// Get all regions that were executed at least once.
    public var executedRegions: [ResolvedRegionCoverage] {
        functions.flatMap { $0.regions.filter { $0.executionCount > 0 } }
    }

    /// Get all regions that were never executed.
    public var unexecutedRegions: [ResolvedRegionCoverage] {
        functions.flatMap { $0.regions.filter { $0.executionCount == 0 } }
    }

    /// Filter coverage to only include functions from specific paths.
    ///
    /// Use this to focus on your project's code and exclude external libraries.
    ///
    /// ```swift
    /// // Only show coverage for files in your project
    /// let projectCoverage = coverage.filtered(
    ///     byPathPrefix: "/Users/me/MyProject/Sources"
    /// )
    ///
    /// // Or exclude system/library paths
    /// let appCoverage = coverage.filtered(
    ///     excludingPathPrefixes: ["/usr", "/System", "/Library"]
    /// )
    /// ```
    ///
    /// - Parameter pathPrefix: Only include functions whose regions are in files
    ///   starting with this path prefix.
    /// - Returns: Filtered coverage data.
    public func filtered(byPathPrefix pathPrefix: String) -> ResolvedCoverage {
        let filteredFunctions = functions.compactMap { func_ -> ResolvedFunctionCoverage? in
            let filteredRegions = func_.regions.filter { region in
                region.filename.hasPrefix(pathPrefix)
            }
            guard !filteredRegions.isEmpty else { return nil }
            return ResolvedFunctionCoverage(
                name: func_.name,
                hash: func_.hash,
                regions: filteredRegions,
                executionCount: func_.executionCount
            )
        }

        let filteredFiles = sourceFiles.filter { $0.hasPrefix(pathPrefix) }

        return ResolvedCoverage(functions: filteredFunctions, sourceFiles: filteredFiles)
    }

    /// Filter coverage to exclude functions from specific paths.
    ///
    /// - Parameter pathPrefixes: Exclude functions whose regions are in files
    ///   starting with any of these prefixes.
    /// - Returns: Filtered coverage data.
    public func filtered(excludingPathPrefixes pathPrefixes: [String]) -> ResolvedCoverage {
        let filteredFunctions = functions.compactMap { func_ -> ResolvedFunctionCoverage? in
            let filteredRegions = func_.regions.filter { region in
                !pathPrefixes.contains { region.filename.hasPrefix($0) }
            }
            guard !filteredRegions.isEmpty else { return nil }
            return ResolvedFunctionCoverage(
                name: func_.name,
                hash: func_.hash,
                regions: filteredRegions,
                executionCount: func_.executionCount
            )
        }

        let filteredFiles = sourceFiles.filter { file in
            !pathPrefixes.contains { file.hasPrefix($0) }
        }

        return ResolvedCoverage(functions: filteredFunctions, sourceFiles: filteredFiles)
    }
}

/// Coverage information for a single function.
public struct ResolvedFunctionCoverage: Sendable {
    /// The function name
    public let name: String

    /// The function's hash (for matching with profile data).
    public let hash: UInt64

    /// Coverage regions within this function.
    public let regions: [ResolvedRegionCoverage]

    /// The function's entry execution count.
    public let executionCount: UInt64

    init(_ func_: ptk.FunctionCoverage) {
        self.name = String(func_.demangledName)
        self.hash = func_.hash
        self.regions = func_.regions.map { ResolvedRegionCoverage($0) }
        self.executionCount = func_.executionCount
    }

    init(
        name: String,
        hash: UInt64,
        regions: [ResolvedRegionCoverage],
        executionCount: UInt64
    ) {
        self.name = name
        self.hash = hash
        self.regions = regions
        self.executionCount = executionCount
    }
}

/// Coverage information for a source region.
public struct ResolvedRegionCoverage: Sendable {
    /// The source file path.
    public let filename: String

    /// Starting line (1-indexed).
    public let lineStart: UInt32

    /// Starting column (1-indexed).
    public let columnStart: UInt32

    /// Ending line (1-indexed).
    public let lineEnd: UInt32

    /// Ending column (1-indexed).
    public let columnEnd: UInt32

    /// Number of times this region was executed.
    public let executionCount: UInt64

    /// Whether this is a branch region.
    public let isBranch: Bool

    /// Whether this region was executed at least once.
    public var isCovered: Bool {
        executionCount > 0
    }

    init(_ region: ptk.RegionCoverage) {
        self.filename = String(region.filename)
        self.lineStart = region.lineStart
        self.columnStart = region.columnStart
        self.lineEnd = region.lineEnd
        self.columnEnd = region.columnEnd
        self.executionCount = region.executionCount
        self.isBranch = region.isBranch
    }
}

// MARK: - Errors

/// Errors from in-memory coverage operations.
public enum InMemoryCoverageError: Error, CustomStringConvertible {
    /// Failed to load coverage mapping from binary.
    case loadFailed(String)

    public var description: String {
        switch self {
        case .loadFailed(let message):
            return "Failed to load coverage mapping: \(message)"
        }
    }
}

// MARK: - Convenience API

/// Default path prefixes to exclude from coverage (system libraries and dependencies).
private let defaultExcludedPathPrefixes = [
    "/usr",
    "/System",
    "/Library",
    "/Applications/Xcode",
    "/opt/homebrew",
]

/// Check if a path looks like a SwiftPM dependency (contains .build/checkouts/).
private func isSwiftPMDependency(_ path: String) -> Bool {
    path.contains("/.build/checkouts/")
}

/// Filter coverage to exclude dependencies and system libraries.
private func filterToProjectOnly(_ coverage: ResolvedCoverage) -> ResolvedCoverage {
    let filteredFunctions = coverage.functions.compactMap { func_ -> ResolvedFunctionCoverage? in
        let filteredRegions = func_.regions.filter { region in
            let path = region.filename
            // Exclude system paths
            for prefix in defaultExcludedPathPrefixes {
                if path.hasPrefix(prefix) {
                    return false
                }
            }
            // Exclude SwiftPM dependencies
            if isSwiftPMDependency(path) {
                return false
            }
            return true
        }
        guard !filteredRegions.isEmpty else { return nil }
        return ResolvedFunctionCoverage(
            name: func_.name,
            hash: func_.hash,
            regions: filteredRegions,
            executionCount: func_.executionCount
        )
    }

    let filteredFiles = coverage.sourceFiles.filter { file in
        for prefix in defaultExcludedPathPrefixes {
            if file.hasPrefix(prefix) {
                return false
            }
        }
        return !isSwiftPMDependency(file)
    }

    return ResolvedCoverage(functions: filteredFunctions, sourceFiles: filteredFiles)
}

/// Measure coverage of a code block with source-level detail.
///
/// This is the most complete coverage API, providing source locations
/// for all executed code. It uses difference-based measurement to avoid
/// interfering with Xcode and other coverage tooling.
///
/// By default, coverage is filtered to exclude system libraries and
/// package dependencies (files in `.build/checkouts/`, `/usr`, `/System`, etc.).
/// Set `includeAllFiles` to `true` to include coverage for all files.
///
/// ```swift
/// let coverage = try measureSourceCoverage {
///     myFunction()
/// }
///
/// for region in coverage.executedRegions {
///     print("\(region.filename):\(region.lineStart) executed \(region.executionCount)x")
/// }
/// ```
///
/// - Parameters:
///   - includeAllFiles: If `true`, include coverage for all files including
///     dependencies and system libraries. Defaults to `false`.
///   - body: The code to measure.
/// - Returns: Source-level coverage data.
/// - Throws: ``InMemoryCoverageError`` if coverage mapping can't be loaded.
public func measureSourceCoverage<T>(
    includeAllFiles: Bool = false,
    _ body: () throws -> T
) throws -> (result: T, coverage: ResolvedCoverage) {
    let reader = try InMemoryCoverageReader.loadFromCurrentProcess()

    // Snapshot before running code
    guard let before = CoverageCounters.snapshot() else {
        // Coverage not available, return empty
        let result = try body()
        return (result, ResolvedCoverage(functions: [], sourceFiles: []))
    }

    let result = try body()

    // Snapshot after running code
    guard let after = CoverageCounters.snapshot() else {
        return (result, ResolvedCoverage(functions: [], sourceFiles: []))
    }

    // Compute difference (what executed during body)
    let deltaCounters = zip(after.counters, before.counters).map { after, before in
        after >= before ? after - before : 0
    }

    // Resolve coverage from delta
    var coverage = reader.resolveCoverage(counters: deltaCounters)

    // Filter to project files only by default
    if !includeAllFiles {
        coverage = filterToProjectOnly(coverage)
    }

    return (result, coverage)
}

/// Measure coverage of a code block with source-level detail (throwing version).
///
/// By default, coverage is filtered to exclude system libraries and
/// package dependencies. Set `includeAllFiles` to `true` to include all files.
///
/// - Parameters:
///   - includeAllFiles: If `true`, include coverage for all files including
///     dependencies and system libraries. Defaults to `false`.
///   - body: The code to measure.
/// - Returns: Source-level coverage data.
/// - Throws: ``InMemoryCoverageError`` if coverage mapping can't be loaded.
public func measureSourceCoverage(
    includeAllFiles: Bool = false,
    _ body: () throws -> Void
) throws -> ResolvedCoverage {
    let (_, coverage) = try measureSourceCoverage(includeAllFiles: includeAllFiles) {
        try body()
        return ()
    }
    return coverage
}
