//
//  CoverageTrait.swift
//  PropertyTestingKit
//
//  A trait that collects per-test code coverage.
//

import Testing
import Foundation
import PropertyTestingKitInternals

// MARK: - Coverage Detection

/// Check if coverage instrumentation is enabled for this test run.
/// Uses dlsym to check if profile runtime symbols are linked in.
private let _coverageEnabled: Bool = {
    ptk_profilerRuntimeAvailable()
}()

/// Get the output directory for coverage files.
private let _defaultCoverageOutputDirectory: String = {
    if let dir = ProcessInfo.processInfo.environment["COVERAGE_OUTPUT_DIR"] {
        return dir
    }
    return FileManager.default.currentDirectoryPath
}()

// MARK: - CoverageTrait

/// A trait that collects per-test code coverage.
///
/// When this trait is applied to a test or suite, each test case gets its own
/// coverage profile file, enabling analysis of which code paths each test
/// exercises.
///
/// - Important: You must also apply `.serialized` to ensure correct coverage
///   isolation. LLVM profile counters are shared global state, so parallel
///   tests will have incorrect coverage data.
///
/// ## Usage
///
/// Apply to an entire suite (recommended):
///
/// ```swift
/// @Suite(.serialized, .coverage)
/// struct MyTests {
///     @Test func test1() { ... }
///     @Test func test2() { ... }
/// }
/// ```
///
/// Apply to a single test:
///
/// ```swift
/// @Test(.coverage)
/// func testFeature() {
///     // Coverage is written to coverage-testFeature.profraw
/// }
/// ```
///
/// ## Requirements
///
/// Per-test coverage requires building and running tests with coverage enabled:
///
/// ```bash
/// swift test --enable-code-coverage
/// ```
///
/// ## Output
///
/// Coverage files are written to `$COVERAGE_OUTPUT_DIR` (or current directory):
///
/// - `coverage-testName.profraw` for each test
///
/// Merge and view results:
///
/// ```bash
/// xcrun llvm-profdata merge -sparse coverage-*.profraw -o merged.profdata
/// xcrun llvm-cov report .build/debug/TestBundle -instr-profile=merged.profdata
/// ```
public struct CoverageTrait: TestTrait, SuiteTrait {
    /// Whether to reset coverage counters before each test.
    ///
    /// When `true` (default), each test's coverage file only contains the
    /// coverage from that specific test. When `false`, coverage accumulates
    /// across tests.
    public var isolatesTests: Bool

    /// The directory where coverage files are written.
    ///
    /// Defaults to `COVERAGE_OUTPUT_DIR` environment variable or current
    /// working directory.
    public var outputDirectory: String

    /// Create a coverage trait.
    ///
    /// - Parameters:
    ///   - isolatesTests: Whether to reset counters before each test.
    ///   - outputDirectory: Directory for coverage files.
    public init(
        isolatesTests: Bool = true,
        outputDirectory: String? = nil
    ) {
        self.isolatesTests = isolatesTests
        self.outputDirectory = outputDirectory ?? _defaultCoverageOutputDirectory
    }

    public var isRecursive: Bool { true }
}

// MARK: - TestScoping

extension CoverageTrait: TestScoping {
    public func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        // Skip coverage collection if not enabled
        guard _coverageEnabled else {
            try await function()
            return
        }

        // Reset counters to isolate this test's coverage
        if isolatesTests {
            __llvm_profile_reset_counters()
        }

        // Run the test
        do {
            try await function()
        } catch {
            // Write coverage even if test fails
            writeCoverage(for: test, testCase: testCase)
            throw error
        }

        // Write coverage for this test
        writeCoverage(for: test, testCase: testCase)
    }

    private func writeCoverage(for test: Test, testCase: Test.Case?) {
        let filename = coverageFilename(for: test, testCase: testCase)

        filename.withCString { cString in
            __llvm_profile_set_filename(cString)
        }

        _ = __llvm_profile_write_file()
    }

    private func coverageFilename(for test: Test, testCase: Test.Case?) -> String {
        let name = test.name

        // Sanitize for filesystem - only allow safe characters
        let sanitized = String(name.map { char in
            switch char {
            case "a"..."z", "A"..."Z", "0"..."9", "_", "-", ".":
                return char
            default:
                return Character("_")
            }
        })

        return "\(outputDirectory)/coverage-\(sanitized).profraw"
    }
}

// MARK: - Trait Extension

extension Trait where Self == CoverageTrait {
    /// A trait that collects per-test code coverage.
    ///
    /// Apply this trait to tests or suites to generate individual coverage
    /// profiles for each test case.
    ///
    /// - Important: Also apply `.serialized` to ensure correct coverage isolation.
    ///
    /// ```swift
    /// @Suite(.serialized, .coverage)
    /// struct MyTests { ... }
    /// ```
    public static var coverage: Self {
        Self()
    }

    /// A trait that collects per-test code coverage with custom options.
    ///
    /// - Parameters:
    ///   - isolatesTests: Whether to reset counters between tests.
    ///   - outputDirectory: Directory for coverage files.
    public static func coverage(
        isolatesTests: Bool = true,
        outputDirectory: String? = nil
    ) -> Self {
        Self(isolatesTests: isolatesTests, outputDirectory: outputDirectory)
    }
}

// MARK: - Coverage Utilities

extension CoverageTrait {
    /// Whether coverage instrumentation is available for this test run.
    ///
    /// Returns `true` if the test binary was compiled with coverage
    /// instrumentation (`--enable-code-coverage`).
    public static var isAvailable: Bool {
        _coverageEnabled
    }
}
