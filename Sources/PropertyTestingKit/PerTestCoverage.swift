//
//  PerTestCoverage.swift
//  PropertyTestingKit
//

import Foundation

// MARK: - Per-Test Coverage API

/// Per-test coverage utilities.
///
/// Use the ``CoverageTrait`` (`.coverage`) to collect isolated code coverage
/// for each test.
///
/// ## Usage
///
/// ```swift
/// import Testing
/// import PropertyTestingKit
///
/// @Suite(.coverage(outputDirectory: "/tmp"))
/// struct MyTests {
///     @Test func test1() { ... }
///     @Test func test2() { ... }
/// }
/// ```
///
/// Run with: `swift test --enable-code-coverage`
///
/// The trait automatically:
/// - Serializes test execution (LLVM counters are global state)
/// - Resets coverage counters before each test
/// - Writes a separate `.profraw` file after each test
///
/// ## Analyzing Results
///
/// ```bash
/// # Merge coverage for a single test
/// xcrun llvm-profdata merge -sparse /tmp/coverage-test1.profraw -o single.profdata
///
/// # View coverage
/// xcrun llvm-cov show .build/.../YourTests -instr-profile=single.profdata
/// ```
public enum PerTestCoverage {
    /// Whether coverage instrumentation is available for this test run.
    ///
    /// Returns `true` if:
    /// - The test binary was compiled with `--enable-code-coverage`
    /// - The `LLVM_PROFILE_FILE` environment variable is set
    public static var isAvailable: Bool {
        CoverageTrait.isAvailable
    }
}
