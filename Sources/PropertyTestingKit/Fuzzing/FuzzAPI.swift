//
//  FuzzAPI.swift
//  PropertyTestingKit
//
//  Public API for coverage-guided fuzz testing.
//

import Foundation
import Testing
import Dependencies

// MARK: - Public Fuzz API

/// Run a coverage-guided fuzz test.
///
/// This function combines property-based testing with coverage guidance:
/// 1. First run: Explores inputs to maximize code coverage, saves minimal corpus
/// 2. Subsequent runs: Replays saved corpus, re-fuzzes if coverage changes
///
/// ## Usage
///
/// ```swift
/// @Test func testParser() throws {
///     // Basic usage with default seeds
///     try fuzz { (input: String) in
///         let result = parse(input)
///         #expect(result.isValid || result.hasError)
///     }
/// }
///
/// @Test func testNumberParser() throws {
///     // Provide domain-specific seeds to guide the fuzzer
///     try fuzz(seeds: ["0", "-0", "-1", "9223372036854775807", "abc"]) { (input: String) in
///         let parsed = NumberParser.parse(input)
///         if let n = parsed {
///             #expect(String(n) == input || input.hasPrefix("0"))
///         }
///     }
/// }
/// ```
///
/// ## Corpus Storage
///
/// The corpus is saved alongside tests in a `.corpus` directory.
/// You can commit this to version control for deterministic CI runs.
///
/// ## Requirements
///
/// - Build with coverage: `swift test --enable-code-coverage`
/// - Input type must conform to `Fuzzable & Codable`
/// - Tests must run serially (coverage counters are global state)
///
/// - Parameters:
///   - seeds: Domain-specific seed values to guide the fuzzer. These are added
///     to the type's default `fuzz` values. Use this to target specific edge cases.
///   - iterations: Maximum fuzzing iterations (default: 10,000).
///   - duration: Maximum fuzzing time in seconds (default: 60).
///   - file: Source file (auto-filled).
///   - function: Test function name (auto-filled).
///   - test: The test closure receiving fuzzed inputs.
///
/// - Throws: Re-throws test failures, or throws if fuzzing finds failures.
@discardableResult
public func fuzz<Input: Fuzzable & Codable & Sendable>(
    seeds: [Input] = [],
    iterations: Int = 10_000,
    duration: TimeInterval = 60,
    file: StaticString = #file,
    function: StaticString = #function,
    test: (Input) throws -> Void
) throws -> FuzzResult<Input> {
    @Dependency(\.environment) var environment
    let corpusDir = corpusDirectory(file: file, function: function)

    let config = FuzzEngine<Input>.Config(
        maxIterations: iterations,
        maxDuration: duration,
        verbose: environment.environment()["FUZZ_VERBOSE"] != nil
    )

    let engine = FuzzEngine<Input>(config: config, corpusDirectory: corpusDir)
    let result = engine.run(additionalSeeds: seeds, test: test)

    // Report failures using Swift Testing
    for (input, error) in result.failures {
        Issue.record(
            Comment(rawValue: "Fuzz failure with input: \(input)"),
            sourceLocation: SourceLocation(
                fileID: String(describing: file),
                filePath: String(describing: file),
                line: 1,
                column: 1
            )
        )
        Issue.record(error)
    }

    // Throw if there were any failures
    if let firstFailure = result.failures.first {
        throw FuzzError.testFailed(
            input: "\(firstFailure.input)",
            underlyingError: firstFailure.error
        )
    }

    return result
}

// MARK: - Multi-Input Fuzz (Variadic)
// NOTE: Variadic generics support is blocked by a Swift 6.2.1 compiler bug (signal 11 crash).
// The compiler crashes when iterating over arrays of variadic tuples and using pack expansion.
// See: https://github.com/apple/swift/issues/XXXXX (file a bug report)
//
// Once the compiler is fixed, the variadic fuzz function can be re-implemented to support:
// try fuzz { (a: Int, b: String) in ... }

// MARK: - Corpus Directory Resolution

/// Determine the corpus directory for a test.
///
/// Structure: `<TestTarget>/.corpus/<TestFunction>/`
private func corpusDirectory(file: StaticString, function: StaticString) -> URL {
    let filePath = String(describing: file)
    let functionName = sanitizeFunctionName(String(describing: function))

    // Find the test target directory (parent of the source file)
    let fileURL = URL(fileURLWithPath: filePath)
    let testDir = fileURL.deletingLastPathComponent()

    return testDir
        .appendingPathComponent(".corpus", isDirectory: true)
        .appendingPathComponent(functionName, isDirectory: true)
}

/// Sanitize function name for use as directory name.
private func sanitizeFunctionName(_ name: String) -> String {
    // Remove parentheses and parameters: "testFoo(bar:)" -> "testFoo"
    // prefix(while:) handles empty strings naturally by returning empty
    let base = name.prefix(while: { $0 != "(" })
    return String(base)
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "\\", with: "_")
        .replacingOccurrences(of: ":", with: "_")
}

// MARK: - Fuzz Errors

/// Errors that can occur during fuzzing.
public enum FuzzError: Error, LocalizedError {
    /// A test failed with a specific input.
    case testFailed(input: String, underlyingError: Error)

    /// Coverage is not available (not built with coverage enabled).
    case coverageUnavailable

    /// Failed to load or save corpus.
    case corpusError(String)

    public var errorDescription: String? {
        switch self {
        case .testFailed(let input, let error):
            return "Fuzz test failed with input '\(input)': \(error)"
        case .coverageUnavailable:
            return "Coverage instrumentation not available. Build with --enable-code-coverage"
        case .corpusError(let message):
            return "Corpus error: \(message)"
        }
    }
}

// MARK: - Configuration via Environment

/// Environment variables for configuring fuzz behavior:
/// - `FUZZ_VERBOSE=1`: Enable verbose logging
/// - `FUZZ_ITERATIONS=N`: Override max iterations
/// - `FUZZ_DURATION=N`: Override max duration (seconds)
/// - `FUZZ_FORCE_REFUZZ=1`: Ignore saved corpus, always fuzz fresh

extension FuzzEngine.Config {
    /// Create config from environment variables.
    public static func fromEnvironment() -> FuzzEngine<Input>.Config {
        @Dependency(\.environment) var environment
        let env = environment.environment()

        var config = FuzzEngine<Input>.Config()

        if let iterations = env["FUZZ_ITERATIONS"].flatMap(Int.init) {
            config.maxIterations = iterations
        }

        if let duration = env["FUZZ_DURATION"].flatMap(TimeInterval.init) {
            config.maxDuration = duration
        }

        if env["FUZZ_VERBOSE"] != nil {
            config.verbose = true
        }

        return config
    }
}
