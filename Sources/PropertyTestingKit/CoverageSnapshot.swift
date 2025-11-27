//
//  CoverageSnapshot.swift
//  PropertyTestingKit
//
//  Capture and inspect code coverage programmatically.
//

import Foundation
import PropertyTestingKitInternals

// MARK: - CoverageSnapshot

/// A snapshot of code coverage data captured during execution.
///
/// Use ``withCoverage(_:)`` to capture a snapshot:
///
/// ```swift
/// let (result, coverage) = try withCoverage {
///     myFunction()
/// }
///
/// // Inspect which files were covered
/// let report = try coverage.generateReport()
/// ```
public struct CoverageSnapshot: Sendable {
    /// Path to the raw profile data file (.profraw).
    public let profilePath: String

    /// Creates a coverage snapshot from a profile path.
    public init(profilePath: String) {
        self.profilePath = profilePath
    }

    /// Whether the profile file exists.
    public var exists: Bool {
        FileManager.default.fileExists(atPath: profilePath)
    }

    /// Size of the profile file in bytes.
    public var fileSize: UInt64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: profilePath) else {
            return nil
        }
        return attrs[.size] as? UInt64
    }

    /// Delete the profile file.
    public func delete() throws {
        try FileManager.default.removeItem(atPath: profilePath)
    }

    // MARK: - Report Generation

    /// Generate a coverage report for the given binary.
    ///
    /// This runs `llvm-cov report` and returns the text output.
    ///
    /// ```swift
    /// let coverage = try withCoverage { myFunction() }
    /// let report = try coverage.report(for: "/path/to/binary")
    /// print(report)
    /// ```
    ///
    /// - Parameter binaryPath: Path to the instrumented binary.
    /// - Returns: The coverage report as text.
    public func report(for binaryPath: String) throws -> String {
        let profdata = try mergeProfile()
        defer { try? FileManager.default.removeItem(atPath: profdata) }

        return try runLLVMCov(["report", binaryPath, "-instr-profile=\(profdata)"])
    }

    /// Export coverage data as JSON for the given binary.
    ///
    /// This runs `llvm-cov export` and returns parsed JSON.
    ///
    /// - Parameter binaryPath: Path to the instrumented binary.
    /// - Returns: The coverage data as a dictionary.
    public func exportJSON(for binaryPath: String) throws -> [String: Any] {
        let profdata = try mergeProfile()
        defer { try? FileManager.default.removeItem(atPath: profdata) }

        let output = try runLLVMCov(["export", binaryPath, "-instr-profile=\(profdata)"])
        guard let data = output.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CoverageError.parseFailure
        }
        return json
    }

    /// Get line coverage for a specific source file.
    ///
    /// - Parameters:
    ///   - file: Path to the source file.
    ///   - binaryPath: Path to the instrumented binary.
    /// - Returns: A dictionary mapping line numbers to execution counts.
    public func lineCoverage(for file: String, binaryPath: String) throws -> [Int: Int] {
        let profdata = try mergeProfile()
        defer { try? FileManager.default.removeItem(atPath: profdata) }

        let output = try runLLVMCov([
            "show", binaryPath,
            "-instr-profile=\(profdata)",
            "-path-equivalence=.,\(FileManager.default.currentDirectoryPath)",
            file
        ])

        // Parse line coverage from output
        // Format: "   12|     5|    code here" where 5 is execution count
        var coverage: [Int: Int] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 2)
            guard parts.count >= 2 else { continue }

            let lineNumStr = parts[0].trimmingCharacters(in: .whitespaces)
            let countStr = parts[1].trimmingCharacters(in: .whitespaces)

            guard let lineNum = Int(lineNumStr),
                  let count = Int(countStr) else { continue }

            coverage[lineNum] = count
        }

        return coverage
    }

    // MARK: - Private Helpers

    /// Merge the profraw file into profdata format.
    private func mergeProfile() throws -> String {
        let profdataPath = profilePath.replacingOccurrences(of: ".profraw", with: ".profdata")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["llvm-profdata", "merge", "-sparse", profilePath, "-o", profdataPath]

        let pipe = Pipe()
        process.standardError = pipe

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw CoverageError.mergeFailure(stderr)
        }

        return profdataPath
    }

    /// Run llvm-cov with the given arguments.
    private func runLLVMCov(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["llvm-cov"] + arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorOutput = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw CoverageError.llvmCovFailure(errorOutput)
        }

        return String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}

// MARK: - Coverage Capture

/// Execute a closure and capture its code coverage.
///
/// This function:
/// 1. Resets all coverage counters to zero
/// 2. Executes the provided closure
/// 3. Writes coverage data to a temporary file
/// 4. Returns both the closure's result and the coverage snapshot
///
/// ## Example
///
/// ```swift
/// let (result, coverage) = try withCoverage {
///     return myFunction(input: 42)
/// }
///
/// print("Result: \(result)")
/// print("Coverage file: \(coverage.profilePath)")
/// ```
///
/// ## Requirements
///
/// Coverage instrumentation must be enabled:
/// ```bash
/// swift test --enable-code-coverage
/// ```
///
/// - Parameter body: The closure to execute while capturing coverage.
/// - Returns: A tuple containing the closure's return value and the coverage snapshot.
/// - Throws: Rethrows any error from the closure, or ``CoverageError`` if
///   coverage instrumentation is not available.
public func withCoverage<T>(
    _ body: () throws -> T
) throws -> (result: T, coverage: CoverageSnapshot) {
    guard CoverageTrait.isAvailable else {
        throw CoverageError.instrumentationNotAvailable
    }

    // Generate unique filename
    let filename = "/tmp/coverage-\(UUID().uuidString).profraw"

    // Reset counters to isolate this execution's coverage
    __llvm_profile_reset_counters()

    // Execute the closure
    let result: T
    do {
        result = try body()
    } catch {
        // Still capture coverage on failure
        writeProfile(to: filename)
        throw error
    }

    // Write coverage data
    writeProfile(to: filename)

    return (result, CoverageSnapshot(profilePath: filename))
}

/// Execute an async closure and capture its code coverage.
///
/// Async version of ``withCoverage(_:)``.
///
/// - Parameter body: The async closure to execute while capturing coverage.
/// - Returns: A tuple containing the closure's return value and the coverage snapshot.
/// - Throws: Rethrows any error from the closure, or ``CoverageError`` if
///   coverage instrumentation is not available.
public func withCoverage<T>(
    _ body: () async throws -> T
) async throws -> (result: T, coverage: CoverageSnapshot) {
    guard CoverageTrait.isAvailable else {
        throw CoverageError.instrumentationNotAvailable
    }

    // Generate unique filename
    let filename = "/tmp/coverage-\(UUID().uuidString).profraw"

    // Reset counters to isolate this execution's coverage
    __llvm_profile_reset_counters()

    // Execute the closure
    let result: T
    do {
        result = try await body()
    } catch {
        // Still capture coverage on failure
        writeProfile(to: filename)
        throw error
    }

    // Write coverage data
    writeProfile(to: filename)

    return (result, CoverageSnapshot(profilePath: filename))
}

/// Execute a closure and capture its code coverage (discarding the result).
///
/// Convenience overload for closures that return Void.
///
/// ```swift
/// let coverage = try withCoverage {
///     performSideEffect()
/// }
/// ```
///
/// - Parameter body: The closure to execute while capturing coverage.
/// - Returns: The coverage snapshot.
/// - Throws: Rethrows any error from the closure.
@discardableResult
public func withCoverage(
    _ body: () throws -> Void
) throws -> CoverageSnapshot {
    let (_, coverage) = try withCoverage(body)
    return coverage
}

/// Execute an async closure and capture its code coverage (discarding the result).
@discardableResult
public func withCoverage(
    _ body: () async throws -> Void
) async throws -> CoverageSnapshot {
    let (_, coverage) = try await withCoverage(body)
    return coverage
}

// MARK: - Private Helpers

private func writeProfile(to filename: String) {
    filename.withCString { cString in
        __llvm_profile_set_filename(cString)
    }
    _ = __llvm_profile_write_file()
}

// MARK: - CoverageError

/// Errors that can occur during coverage capture or analysis.
public enum CoverageError: Error, CustomStringConvertible {
    /// Coverage instrumentation is not available.
    ///
    /// This occurs when the code was not compiled with `--enable-code-coverage`.
    case instrumentationNotAvailable

    /// Failed to write the coverage profile.
    case writeFailure(path: String)

    /// Failed to merge profile data.
    case mergeFailure(String)

    /// Failed to run llvm-cov.
    case llvmCovFailure(String)

    /// Failed to parse coverage data.
    case parseFailure

    public var description: String {
        switch self {
        case .instrumentationNotAvailable:
            return "Coverage instrumentation not available. Build with: swift test --enable-code-coverage"
        case .writeFailure(let path):
            return "Failed to write coverage profile to: \(path)"
        case .mergeFailure(let message):
            return "Failed to merge profile data: \(message)"
        case .llvmCovFailure(let message):
            return "llvm-cov failed: \(message)"
        case .parseFailure:
            return "Failed to parse coverage data"
        }
    }
}
