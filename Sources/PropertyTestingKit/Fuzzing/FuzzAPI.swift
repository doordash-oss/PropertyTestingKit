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

// MARK: - Variadic Fuzz Input Pack

/// A wrapper that packs multiple fuzzable inputs into a single `Fuzzable` type.
///
/// This enables the fuzz engine to work with multiple input types while maintaining
/// a single-type-parameter internal architecture.
public struct FuzzInputPack<each T: Fuzzable & Codable & Sendable>: Fuzzable, Codable, Sendable {
    /// The packed inputs.
    public let values: (repeat each T)

    public init(_ values: repeat each T) {
        self.values = (repeat each values)
    }

    /// Generate fuzz values from the cartesian product of each type's fuzz values.
    public static var fuzz: [FuzzInputPack<repeat each T>] {
        cartesianProductFuzz()
    }

    /// Mutate by randomly selecting one component to mutate.
    public func mutate() -> [FuzzInputPack<repeat each T>] {
        // Collect all possible mutations
        var results: [FuzzInputPack<repeat each T>] = []

        // For each component, try mutating it while keeping others the same
        var componentIndex = 0
        func tryMutate<U: Fuzzable>(_ value: U, atIndex index: Int) {
            let mutations = value.mutate()
            for mutated in mutations {
                // Create a new pack with this component mutated
                // We need to reconstruct the tuple with the mutated value
                if let newPack = createMutatedPack(mutating: index, with: mutated) {
                    results.append(newPack)
                }
            }
            componentIndex += 1
        }

        componentIndex = 0
        (repeat tryMutate(each values, atIndex: componentIndex))

        return results
    }

    // Helper to create a mutated pack at a specific index
    private func createMutatedPack<U>(mutating targetIndex: Int, with newValue: U) -> FuzzInputPack<repeat each T>? {
        var currentIndex = 0

        func substituteIfNeeded<V: Fuzzable & Codable & Sendable>(_ value: V) -> V {
            defer { currentIndex += 1 }
            if currentIndex == targetIndex, let casted = newValue as? V {
                return casted
            }
            return value
        }

        let newValues: (repeat each T) = (repeat substituteIfNeeded(each values))
        return FuzzInputPack(repeat each newValues)
    }

    // MARK: - Codable

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let dataList = try container.decode([Data].self)
        var iterator = dataList.makeIterator()
        let jsonDecoder = JSONDecoder()
        self.values = try (repeat jsonDecoder.decode((each T).self, from: iterator.next()!))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        var dataList: [Data] = []
        let jsonEncoder = JSONEncoder()
        (repeat try dataList.append(jsonEncoder.encode(each values)))
        try container.encode(dataList)
    }
}

/// Generate the cartesian product of fuzz values for variadic types.
private func cartesianProductFuzz<each T: Fuzzable & Codable & Sendable>() -> [FuzzInputPack<repeat each T>] {
    // Get fuzz arrays for each type
    var counts: [Int] = []
    (repeat counts.append((each T).fuzz.count))

    // If any array is empty, return empty result
    guard !counts.contains(0) else { return [] }

    // Calculate total combinations
    let total = counts.reduce(1, *)
    var results: [FuzzInputPack<repeat each T>] = []

    for i in 0..<total {
        // Calculate indices for this combination
        var indices: [Int] = []
        var remaining = i
        for count in counts.reversed() {
            indices.insert(remaining % count, at: 0)
            remaining /= count
        }

        // Build the pack for this combination
        var indexIterator = indices.makeIterator()
        func getValue<U: Fuzzable>(_: U.Type) -> U {
            U.fuzz[indexIterator.next()!]
        }

        let pack = FuzzInputPack<repeat each T>(repeat getValue((each T).self))
        results.append(pack)
    }

    return results
}

// MARK: - Variadic Fuzz API

/// Run a coverage-guided fuzz test with multiple input types.
///
/// This variadic version allows testing functions that take multiple parameters:
///
/// ```swift
/// @Test func testMultiInput() throws {
///     try fuzz { (count: Int, name: String) in
///         let result = process(count: count, name: name)
///         #expect(result.isValid)
///     }
/// }
///
/// @Test func testWithSeeds() throws {
///     try fuzz(seeds: [(0, ""), (1, "test"), (-1, "edge")]) { (count: Int, name: String) in
///         // ...
///     }
/// }
/// ```
///
/// Seeds are generated from the cartesian product of each type's `fuzz` values if not provided.
///
/// - Parameters:
///   - seeds: Domain-specific seed values as tuples.
///   - iterations: Maximum fuzzing iterations (default: 10,000).
///   - duration: Maximum fuzzing time in seconds (default: 60).
///   - file: Source file (auto-filled).
///   - function: Test function name (auto-filled).
///   - test: The test closure receiving fuzzed inputs.
///
/// - Throws: Re-throws test failures, or throws if fuzzing finds failures.
@discardableResult
public func fuzz<each Input: Fuzzable & Codable & Sendable>(
    seeds: [(repeat each Input)] = [],
    iterations: Int = 10_000,
    duration: TimeInterval = 60,
    file: StaticString = #file,
    function: StaticString = #function,
    test: (repeat each Input) throws -> Void
) throws -> FuzzResult<FuzzInputPack<repeat each Input>> {
    @Dependency(\.environment) var environment
    let corpusDir = corpusDirectory(file: file, function: function)

    let config = FuzzEngine<FuzzInputPack<repeat each Input>>.Config(
        maxIterations: iterations,
        maxDuration: duration,
        verbose: environment.environment()["FUZZ_VERBOSE"] != nil
    )

    // Convert seeds to FuzzInputPack
    let packSeeds = seeds.map { seed in
        FuzzInputPack<repeat each Input>(repeat each seed)
    }

    let engine = FuzzEngine<FuzzInputPack<repeat each Input>>(config: config, corpusDirectory: corpusDir)

    // Wrap the test to unpack inputs
    let result = engine.run(additionalSeeds: packSeeds) { pack in
        try test(repeat each pack.values)
    }

    // Report failures using Swift Testing
    for (input, error) in result.failures {
        Issue.record(
            Comment(rawValue: "Fuzz failure with input: \(input.values)"),
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
            input: "\(firstFailure.input.values)",
            underlyingError: firstFailure.error
        )
    }

    return result
}

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
