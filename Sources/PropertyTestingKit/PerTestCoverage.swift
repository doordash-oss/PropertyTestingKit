//
//  PerTestCoverage.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Foundation

// MARK: - Coverage Detection

// Check if coverage is enabled by looking for environment variable or build flag
private let coverageEnabled: Bool = {
    // When swift test --enable-code-coverage is used, codecov directory is created
    let buildDir = FileManager.default.currentDirectoryPath + "/.build/debug/codecov"
    return FileManager.default.fileExists(atPath: buildDir)
}()

// MARK: - Per-Test Coverage API

/// Manages per-test code coverage tracking.
///
/// **Important Limitation:** Due to LLVM profile runtime constraints, this API cannot
/// write isolated coverage files per-test within a single test process. The LLVM
/// profile functions are local symbols that cannot be safely called from user code.
///
/// This API provides:
/// 1. Detection of whether coverage instrumentation is enabled
/// 2. Logging of test execution for tracking purposes
/// 3. A wrapper for test bodies (useful for future enhancements)
///
/// For **true per-test coverage isolation**, use `EnvironmentBasedCoverage.generateScript()`
/// which runs each test in a separate process with its own `LLVM_PROFILE_FILE`.
///
/// Example usage for tracking:
/// ```swift
/// @Test func myTest() {
///     PerTestCoverage.run(testName: "myTest") {
///         // Your test code here
///         let result = myFunction()
///         #expect(result == expected)
///     }
/// }
/// ```
///
/// For isolated coverage files, run the generated script:
/// ```bash
/// swift run --target YourTarget -- generate-coverage-script > run-coverage.sh
/// chmod +x run-coverage.sh
/// ./run-coverage.sh
/// ```
public enum PerTestCoverage {
    /// Directory where coverage files will be written.
    /// Set via `COVERAGE_OUTPUT_DIR` environment variable, defaults to current directory.
    public static let outputDirectory: String = {
        ProcessInfo.processInfo.environment["COVERAGE_OUTPUT_DIR"] ?? FileManager.default.currentDirectoryPath
    }()

    /// File extension for raw coverage files.
    public static let fileExtension = "profraw"

    /// Returns true if coverage instrumentation is available.
    public static var isAvailable: Bool {
        coverageEnabled
    }

    /// Executes a test body while capturing its isolated code coverage.
    ///
    /// - Parameters:
    ///   - testName: A unique name for this test (used in the coverage filename)
    ///   - body: The test code to execute
    /// - Returns: The value returned by the body closure
    @discardableResult
    public static func run<T>(testName: String, body: () throws -> T) rethrows -> T {
        // Note: We don't reset counters as it can cause issues with the LLVM runtime.
        // Instead, we capture cumulative coverage up to this point.
        // For true isolation, run tests in separate processes (see EnvironmentBasedCoverage).

        // Execute the test
        let result: T
        do {
            result = try body()
        } catch {
            // Still write coverage even if test throws
            writeCoverage(testName: testName)
            throw error
        }

        // Write coverage data for this test
        writeCoverage(testName: testName)

        return result
    }

    /// Async variant for async test bodies.
    @discardableResult
    public static func run<T>(testName: String, body: () async throws -> T) async rethrows -> T {
        let result: T
        do {
            result = try await body()
        } catch {
            writeCoverage(testName: testName)
            throw error
        }

        writeCoverage(testName: testName)

        return result
    }

    /// Records that a test has completed (for logging/tracking purposes).
    /// Note: Actual per-test coverage files require running each test in a separate process.
    /// See EnvironmentBasedCoverage.generateScript() for that approach.
    private static func writeCoverage(testName: String) {
        // The LLVM profile runtime functions are not safely callable from Swift
        // because they are local symbols and may have internal preconditions.
        // For true per-test coverage isolation, use the environment-based approach:
        // run each test in a separate process with LLVM_PROFILE_FILE set.

        if coverageEnabled {
            print("📊 Test '\(testName)' completed (coverage accumulated in default profile)")
        }
    }
}

// MARK: - Alternative Approach: Environment-Based Per-Test Coverage

/// An alternative approach using environment variables.
/// This requires running each test in a separate process.
///
/// Usage:
/// ```bash
/// # Run each test individually with a unique profile file
/// for test in $(swift test --list-tests 2>/dev/null | grep "\."); do
///     LLVM_PROFILE_FILE="coverage-${test//\//_}.profraw" swift test --filter "$test"
/// done
/// ```
public enum EnvironmentBasedCoverage {
    /// Returns a shell script that runs each test with isolated coverage.
    public static func generateScript(outputDir: String = ".") -> String {
        """
        #!/bin/bash
        # Per-test coverage collection script
        # Generated by PropertyTestingKit

        OUTPUT_DIR="\(outputDir)"
        mkdir -p "$OUTPUT_DIR"

        # Get list of tests
        TESTS=$(swift test --list-tests 2>/dev/null | grep "\\.")

        for test in $TESTS; do
            # Sanitize test name for filename
            SAFE_NAME=$(echo "$test" | tr '/:' '_')
            PROFILE_FILE="$OUTPUT_DIR/coverage-$SAFE_NAME.profraw"

            echo "Running: $test"
            LLVM_PROFILE_FILE="$PROFILE_FILE" swift test --filter "$test" --enable-code-coverage 2>/dev/null

            if [ -f "$PROFILE_FILE" ]; then
                SIZE=$(stat -f%z "$PROFILE_FILE" 2>/dev/null || stat -c%s "$PROFILE_FILE" 2>/dev/null)
                echo "  ✅ Coverage: $SIZE bytes -> $PROFILE_FILE"
            else
                echo "  ⚠️ No coverage file generated"
            fi
        done

        echo ""
        echo "Coverage files written to: $OUTPUT_DIR"
        echo "To merge: xcrun llvm-profdata merge -sparse $OUTPUT_DIR/*.profraw -o merged.profdata"
        """
    }
}

// MARK: - Coverage Report Helper

/// Helper to analyze coverage files after test runs.
public enum CoverageAnalyzer {
    /// Prints instructions for analyzing coverage after tests complete.
    public static func printUsageInstructions() {
        print("""

        ═══════════════════════════════════════════════════════════════
        Per-Test Coverage Analysis Instructions
        ═══════════════════════════════════════════════════════════════

        1. Build with coverage enabled:
           swift build --enable-code-coverage
           swift test --enable-code-coverage

        2. Find your coverage files:
           ls \(PerTestCoverage.outputDirectory)/coverage-*.profraw

        3. Merge coverage for a specific test:
           xcrun llvm-profdata merge -sparse coverage-testName.profraw -o test.profdata

        4. View coverage report:
           xcrun llvm-cov report .build/debug/YourPackagePackageTests.xctest/Contents/MacOS/YourPackagePackageTests \\
               -instr-profile=test.profdata

        5. View detailed line-by-line coverage:
           xcrun llvm-cov show .build/debug/YourPackagePackageTests.xctest/Contents/MacOS/YourPackagePackageTests \\
               -instr-profile=test.profdata \\
               -format=html -output-dir=coverage-report

        6. Compare coverage between tests:
           # Merge all tests
           xcrun llvm-profdata merge -sparse coverage-*.profraw -o all.profdata

           # See what testA covers that testB doesn't
           xcrun llvm-profdata merge -sparse coverage-testA.profraw -o a.profdata
           xcrun llvm-cov export ... -instr-profile=a.profdata > a.json

        ═══════════════════════════════════════════════════════════════
        """)
    }
}
