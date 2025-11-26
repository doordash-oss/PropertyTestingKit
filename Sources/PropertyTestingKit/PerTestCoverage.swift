//
//  PerTestCoverage.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Foundation

// MARK: - LLVM Profile Runtime Interface

// These functions are provided by the LLVM profile runtime when code is compiled
// with coverage instrumentation (-profile-generate or --enable-code-coverage).
// We use dlsym to safely check if they exist before calling.

private let _llvm_profile_reset_counters: (@convention(c) () -> Void)? = {
    guard let handle = dlopen(nil, RTLD_NOW),
          let sym = dlsym(handle, "__llvm_profile_reset_counters") else {
        return nil
    }
    return unsafeBitCast(sym, to: (@convention(c) () -> Void).self)
}()

private let _llvm_profile_write_file: (@convention(c) () -> Int32)? = {
    guard let handle = dlopen(nil, RTLD_NOW),
          let sym = dlsym(handle, "__llvm_profile_write_file") else {
        return nil
    }
    return unsafeBitCast(sym, to: (@convention(c) () -> Int32).self)
}()

private let _llvm_profile_set_filename: (@convention(c) (UnsafePointer<CChar>) -> Void)? = {
    guard let handle = dlopen(nil, RTLD_NOW),
          let sym = dlsym(handle, "__llvm_profile_set_filename") else {
        return nil
    }
    return unsafeBitCast(sym, to: (@convention(c) (UnsafePointer<CChar>) -> Void).self)
}()

// MARK: - Per-Test Coverage API

/// Manages per-test code coverage collection.
///
/// Usage:
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
/// Or use the throwing variant:
/// ```swift
/// @Test func myTest() throws {
///     try PerTestCoverage.run(testName: "myTest") {
///         try someThrowingOperation()
///     }
/// }
/// ```
///
/// After running tests, coverage files will be in the output directory.
/// Merge them with: `llvm-profdata merge -sparse *.profraw -o merged.profdata`
/// View report with: `llvm-cov report .build/debug/YourTestBundle -instr-profile=merged.profdata`
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
        _llvm_profile_reset_counters != nil &&
        _llvm_profile_write_file != nil &&
        _llvm_profile_set_filename != nil
    }

    /// Executes a test body while capturing its isolated code coverage.
    ///
    /// - Parameters:
    ///   - testName: A unique name for this test (used in the coverage filename)
    ///   - body: The test code to execute
    /// - Returns: The value returned by the body closure
    @discardableResult
    public static func run<T>(testName: String, body: () throws -> T) rethrows -> T {
        // Reset counters to isolate this test's coverage (if available)
        _llvm_profile_reset_counters?()

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
        _llvm_profile_reset_counters?()

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

    /// Writes coverage data to a file named after the test.
    private static func writeCoverage(testName: String) {
        guard let setFilename = _llvm_profile_set_filename,
              let writeFile = _llvm_profile_write_file else {
            // Coverage not available, silently skip
            return
        }

        // Sanitize test name for use as filename
        let sanitized = testName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .replacingOccurrences(of: " ", with: "_")

        let filename = "\(outputDirectory)/coverage-\(sanitized).\(fileExtension)"

        filename.withCString { cString in
            setFilename(cString)
        }

        let result = writeFile()
        if result != 0 {
            print("⚠️ Coverage write failed for '\(testName)' (error: \(result))")
        } else {
            // Check file size
            if let attrs = try? FileManager.default.attributesOfItem(atPath: filename),
               let size = attrs[.size] as? Int {
                if size == 0 {
                    print("⚠️ Coverage file for '\(testName)' is empty (0 bytes)")
                } else {
                    print("✅ Coverage written for '\(testName)': \(size) bytes -> \(filename)")
                }
            }
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
