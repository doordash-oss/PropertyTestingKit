// Copyright 2026 DoorDash, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

//  Public API for coverage-guided fuzz testing.
//

import Foundation
import Testing
import Dependencies

// MARK: - Public Fuzz API

/// Run a coverage-guided fuzz test with explicit mutators.
///
/// This function combines property-based testing with coverage guidance:
/// 1. First run: Explores inputs to maximize code coverage, saves minimal corpus
/// 2. Subsequent runs: Replays saved corpus, checks for crashes (regression)
///
/// ## Usage
///
/// ```swift
/// @Test func testParser() throws {
///     // Basic usage with default mutators (uses MutatorProviding conformance)
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
///
/// @Test func testWithMutators() throws {
///     // Use custom mutators for domain-specific fuzzing
///     try fuzz(using: String.mutators(.phoneNumbers, .emails)) { (input: String) in
///         validateInput(input)
///     }
/// }
///
/// @Test func testMultipleInputs() throws {
///     // Multiple inputs with custom mutators for each
///     try fuzz(using: String.mutators(.sql), Int.mutators(.boundaries)) { (query: String, limit: Int) in
///         executeQuery(query, limit: limit)
///     }
/// }
///
/// @Test func testWithGapDetection() throws {
///     // Enable coverage gap detection
///     try fuzz(plugins: CoverageGapPlugin()) { (input: String) in
///         parse(input)
///     }
/// }
/// ```
///
/// ## Corpus Storage
///
/// The corpus is saved alongside tests in a `Corpus` directory.
/// You can commit this to version control for deterministic CI runs.
///
/// ## Requirements
///
/// - Build with sanitizer coverage: `-sanitize-coverage=edge,pc-table`
/// - Input type must conform to `Codable & Sendable`
/// - **Coverage isolation**: The fuzzer uses task-keyed coverage maps that provide
///   true per-task isolation. Multiple fuzz tests can run concurrently without
///   coverage contamination, even when tasks share threads.
///
/// - Parameters:
///   - mutators: Mutators for each input type. Pass one mutator per input.
///     Use `String.mutators(...)`, `Int.mutators(...)`, etc. for domain-specific fuzzing.
///   - seeds: Domain-specific seed values to guide the fuzzer. These are added
///     to the mutator's seed values. Use this to target specific edge cases.
///   - duration: Maximum fuzzing time in seconds (default: 60).
///   - persistence: How the on-disk corpus is treated: `.auto` (replay if a corpus
///     exists, else fuzz fresh and save — the default), `.replace` (delete then fuzz),
///     or `.extend` (load corpus as seeds, then fuzz). To verify a corpus without
///     fuzzing, use `regress(...)` instead. Can be overridden suite-wide via the
///     `FUZZ_CORPUS_MODE` environment variable.
///   - parallelism: Number of parallel fuzz engines to run. Each engine runs
///     independently with its portion of seeds distributed round-robin.
///     Results are merged at the end. Defaults to the number of available processors.
///   - plugins: Factory for the per-engine plugins. Defaults to
///     `{ [.corpusMutation()] }`. Analysis plugins (`AnalysisPlugin`) can be lifted in
///     with `.asFuzzPlugin()`.
///   - filePath: Source file path (auto-filled).
///   - function: Test function name (auto-filled).
///   - test: The test closure receiving fuzzed inputs.
///
/// - Throws: Re-throws test failures, or throws if fuzzing finds failures.

@discardableResult
@inlinable
public func fuzz<each Input: Codable & Sendable>(
    using mutators: repeat Mutator<each Input>,
    seeds: [(repeat each Input)] = [],
    duration: Duration = .seconds(60),
    persistence: CorpusPersistence = .auto,
    coverageStrategy: CoverageStrategyKind = .pathTrie,
    edgeHook: EdgeHook? = nil,
    scheduleFuzzing: Bool = false,
    parallelism: Int = ProcessInfo.processInfo.processorCount,
    plugins: @escaping @Sendable () -> [FuzzPlugin<repeat each Input>] = { [.corpusMutation()] },
    filePath: StaticString = #filePath,
    function: StaticString = #function,
    line: Int = #line,
    test: @escaping @Sendable ((repeat each Input)) async throws -> Void
) async throws -> FuzzResult<repeat each Input> {
    return try await fuzzInternal(
        mutators: (repeat each mutators),
        seeds: seeds,
        duration: duration,
        persistence: persistence,
        coverageStrategy: coverageStrategy,
        edgeHook: edgeHook,
        scheduleFuzzing: scheduleFuzzing,
        parallelism: parallelism,
        plugins: plugins,
        filePath: filePath,
        function: function,
        line: line,
        test: test
    )
}

/// Internal implementation shared by all fuzz overloads.
@usableFromInline
func fuzzInternal<each Input: Codable & Sendable>(
    mutators: (repeat Mutator<each Input>),
    seeds: [(repeat each Input)],
    duration: Duration,
    persistence: CorpusPersistence,
    coverageStrategy: CoverageStrategyKind,
    edgeHook: EdgeHook?,
    scheduleFuzzing: Bool,
    parallelism: Int,
    plugins: @escaping @Sendable () -> [FuzzPlugin<repeat each Input>],
    filePath: StaticString,
    function: StaticString,
    line: Int,
    test: @escaping @Sendable ((repeat each Input)) async throws -> Void
) async throws -> FuzzResult<repeat each Input> {
    @Dependency(\.environment) var environment

    let testFilePath = String(describing: filePath)
    let verbose = environment.environment()["FUZZ_VERBOSE"] != nil
    // Schedule fuzzing installs a process-global task-enqueue hook, so it cannot be
    // shared across parallel engines — force a single engine when it's enabled.
    let effectiveParallelism = scheduleFuzzing ? 1 : max(1, parallelism)
    let corpusDir = corpusDirectory(filePath: filePath, function: function)

    // All corpus policy (load/save/delete, regression replay, parallel orchestration)
    // lives in the coordinator. fuzzInternal resolves the suite-level env override and
    // routes to the fuzz or (env-forced) replay path, then reports failures.
    let result: FuzzResult<repeat each Input>
    switch CorpusPersistence.resolveForFuzz(callSite: persistence) {
    case .fuzz(let resolved):
        result = await runFuzz(
            mutators: mutators,
            userSeeds: seeds,
            corpusDir: corpusDir,
            persistence: resolved,
            parallelism: effectiveParallelism,
            duration: duration,
            verbose: verbose,
            coverageStrategy: coverageStrategy,
            edgeHook: edgeHook,
            scheduleFuzzing: scheduleFuzzing,
            projectPath: projectPath(from: filePath),
            sourceFileID: testFilePath,
            sourceFilePath: testFilePath,
            line: line,
            makeHandlers: plugins,
            test: test
        )
    case .forcedReplay:
        // FUZZ_CORPUS_MODE=regressiononly forces this fuzz call to a verify-only replay.
        // It runs with NO user plugins, so the write-emitting exploration plugins a
        // fuzz call carries never run during the forced regression — the no-write
        // guarantee holds structurally. For analysis during regression, call regress(...).
        result = await runReplay(
            mutators: mutators,
            corpusDir: corpusDir,
            duration: duration,
            verbose: verbose,
            projectPath: projectPath(from: filePath),
            sourceFileID: testFilePath,
            sourceFilePath: testFilePath,
            line: line,
            plugins: { [] },
            test: test
        )
    }

    return try reportFuzzResult(result, filePath: filePath, line: line)
}

/// Internal implementation shared by all regress overloads.
@usableFromInline
func regressInternal<each Input: Codable & Sendable>(
    mutators: (repeat Mutator<each Input>),
    duration: Duration,
    plugins: @escaping @Sendable () -> [AnalysisPlugin<repeat each Input>],
    filePath: StaticString,
    function: StaticString,
    line: Int,
    test: @escaping @Sendable ((repeat each Input)) async throws -> Void
) async throws -> FuzzResult<repeat each Input> {
    @Dependency(\.environment) var environment

    let testFilePath = String(describing: filePath)
    let verbose = environment.environment()["FUZZ_VERBOSE"] != nil
    let corpusDir = corpusDirectory(filePath: filePath, function: function)

    // Replay only — the analysis plugins (which emit only stop/recordIssue) run on both the
    // sync and async paths inside the coordinator; no write action can reach the replay.
    let result = await runReplay(
        mutators: mutators,
        corpusDir: corpusDir,
        duration: duration,
        verbose: verbose,
        projectPath: projectPath(from: filePath),
        sourceFileID: testFilePath,
        sourceFilePath: testFilePath,
        line: line,
        plugins: plugins,
        test: test
    )

    return try reportFuzzResult(result, filePath: filePath, line: line)
}

/// Run a coverage-guided fuzz test using the type's default mutator.
///
/// This version uses the type's `MutatorProviding.defaultMutator` for each input type.
/// For custom mutation strategies, use `fuzz(using:seeds:...)` with explicit mutators.
///
/// - Parameters:
///   - seeds: Domain-specific seed values to guide the fuzzer.
///   - duration: Maximum fuzzing time in seconds (default: 60).
///   - persistence: How the on-disk corpus is treated (`.auto`/`.replace`/`.extend`).
///     To verify a corpus without fuzzing, use `regress(...)`. Can be overridden
///     suite-wide via `FUZZ_CORPUS_MODE`.
///   - parallelism: Number of parallel fuzz engines to run. Defaults to processor count.
///   - plugins: Factory for the per-engine plugins. Defaults to `{ [.corpusMutation()] }`.
///   - filePath: Source file path (auto-filled).
///   - function: Test function name (auto-filled).
///   - test: The test closure receiving fuzzed inputs.
///
/// - Throws: Re-throws test failures, or throws if fuzzing finds failures.
/// Convenience overload that infers mutators from MutatorProviding conformance.
@discardableResult
@inlinable
public func fuzz<each Input: MutatorProviding & Codable & Sendable>(
    seeds: [(repeat each Input)] = [],
    duration: Duration = .seconds(60),
    persistence: CorpusPersistence = .auto,
    coverageStrategy: CoverageStrategyKind = .pathTrie,
    edgeHook: EdgeHook? = nil,
    scheduleFuzzing: Bool = false,
    parallelism: Int = ProcessInfo.processInfo.processorCount,
    plugins: @escaping @Sendable () -> [FuzzPlugin<repeat each Input>] = { [.corpusMutation()] },
    filePath: StaticString = #filePath,
    function: StaticString = #function,
    line: Int = #line,
    test: @escaping @Sendable ((repeat each Input)) async throws -> Void
) async throws -> FuzzResult<repeat each Input> {
    try await fuzz(
        using: repeat (each Input).defaultMutator,
        seeds: seeds,
        duration: duration,
        persistence: persistence,
        coverageStrategy: coverageStrategy,
        edgeHook: edgeHook,
        scheduleFuzzing: scheduleFuzzing,
        parallelism: parallelism,
        plugins: plugins,
        filePath: filePath,
        function: function,
        line: line,
        test: test
    )
}

// MARK: - Public Regress API

/// Replay a saved corpus and verify it still passes — regression testing.
///
/// Unlike `fuzz(...)`, this never explores: it runs exactly the inputs in the saved
/// corpus and fails if any of them now trips the test. Because it only replays, it
/// takes none of the fuzz-only knobs (`seeds`, `coverageStrategy`, `parallelism`,
/// `edgeHook`, mutators) — they would be meaningless here. Its plugins are
/// `AnalysisPlugin`s, which can only emit `stop`/`recordIssue`, so a replay can never be
/// handed a plugin that would mutate the run or the corpus. If no corpus exists, the run
/// is a no-op (it does not fail), so a suite-wide regression pass tolerates not-yet-fuzzed
/// tests. Input types are inferred from the `test` closure.
///
/// - Parameters:
///   - duration: Maximum replay time in seconds (default: 60).
///   - plugins: Factory for analysis plugins (e.g. `[.coverageGap()]`). Defaults
///     to none.
///   - test: The test closure receiving the replayed inputs.
@discardableResult
@inlinable
public func regress<each Input: MutatorProviding & Codable & Sendable>(
    duration: Duration = .seconds(60),
    plugins: @escaping @Sendable () -> [AnalysisPlugin<repeat each Input>] = { [] },
    filePath: StaticString = #filePath,
    function: StaticString = #function,
    line: Int = #line,
    test: @escaping @Sendable ((repeat each Input)) async throws -> Void
) async throws -> FuzzResult<repeat each Input> {
    // Replay does not generate inputs, so the mutators are inert here — supply the
    // type's default mutators purely to satisfy the engine's construction.
    try await regressInternal(
        mutators: (repeat (each Input).defaultMutator),
        duration: duration,
        plugins: plugins,
        filePath: filePath,
        function: function,
        line: line,
        test: test
    )
}

// MARK: - Fuzz Helpers

/// Report fuzz result failures and throw if any occurred.
private func reportFuzzResult<each Input: Codable & Sendable>(
    _ result: FuzzResult<repeat each Input>,
    filePath: StaticString,
    line: Int = #line
) throws -> FuzzResult<repeat each Input> {
    let testFilePath = String(describing: filePath)

    for (index, (input, error, _)) in result.failures.enumerated() {
        // Format the input for readability
        let formattedInput = formatInput(input)

        // Build a comprehensive failure message
        var message = "Fuzz test failure #\(index + 1)"
        message += "\n\nFailing input:\n\(formattedInput)"
        message += "\n\nError:\n\(error)"

        // Add context about the fuzz run
        message += "\n\nFuzz run stats:"
        message += "\n  - Total inputs tested: \(result.stats.totalInputs)"
        message += "\n  - Stop reason: \(result.stats.stopReason.rawValue)"

        Issue.record(
            Comment(rawValue: message),
            sourceLocation: SourceLocation(
                fileID: testFilePath,
                filePath: testFilePath,
                line: line,
                column: 1
            )
        )
    }

    // Note: Analysis plugin issues are now recorded directly via recordIssue actions

    if let firstFailure = result.failures.first {
        throw FuzzError.testFailed(
            input: formatInput(firstFailure.input),
            underlyingError: firstFailure.error,
            timeElapsed: firstFailure.timeElapsed,
            stats: result.stats
        )
    }

    return result
}

/// Format an input value for readable display in failure messages.
private func formatInput<T>(_ input: T) -> String {
    // Try JSON encoding for Codable types (pretty printed)
    if let encodable = input as? Encodable {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(AnyEncodable(encodable)),
           let jsonString = String(data: data, encoding: .utf8) {
            return jsonString
        }
    }

    // Fall back to string description
    let description = String(describing: input)

    // If it's a long string, truncate with ellipsis
    if description.count > 500 {
        let prefix = description.prefix(250)
        let suffix = description.suffix(250)
        return "\(prefix)\n... [\(description.count - 500) characters truncated] ...\n\(suffix)"
    }

    return description
}

/// Type-erased wrapper for encoding any Encodable value.
private struct AnyEncodable: Encodable {
    private let _encode: (Encoder) throws -> Void

    init(_ value: Encodable) {
        self._encode = { encoder in
            try value.encode(to: encoder)
        }
    }

    func encode(to encoder: Encoder) throws {
        try _encode(encoder)
    }
}

// MARK: - Path Resolution

/// Derive the project root path from a test file path.
///
/// Finds the nearest ancestor directory containing Package.swift or .git.
private func projectPath(from filePath: StaticString) -> String? {
    let path = String(describing: filePath)
    var url = URL(fileURLWithPath: path).deletingLastPathComponent()

    // Walk up looking for project root markers
    while url.path != "/" {
        let packageSwift = url.appendingPathComponent("Package.swift")
        let gitDir = url.appendingPathComponent(".git")

        if FileManager.default.fileExists(atPath: packageSwift.path) ||
           FileManager.default.fileExists(atPath: gitDir.path) {
            return url.path
        }

        url = url.deletingLastPathComponent()
    }

    return nil
}

/// Determine the corpus directory for a test.
///
/// Structure: `<TestFileDirectory>/Corpus/<TestFunction>/`
private func corpusDirectory(filePath: StaticString, function: StaticString) -> URL {
    let path = String(describing: filePath)
    let functionName = sanitizeFunctionName(String(describing: function))

    // Get the directory containing the test source file
    // #filePath provides the full filesystem path
    let fileURL = URL(fileURLWithPath: path)
    let testFileDir = fileURL.deletingLastPathComponent()

    return testFileDir
        .appendingPathComponent("Corpus", isDirectory: true)
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
    case testFailed(input: String, underlyingError: Error, timeElapsed: TimeInterval, stats: FuzzStats)

    /// Coverage is not available (not built with coverage enabled).
    case coverageUnavailable

    /// Failed to load or save corpus.
    case corpusError(String)

    public var errorDescription: String? {
        switch self {
        case .testFailed(let input, let error, _, _):
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
///
/// - `FUZZ_VERBOSE=1`: Enable verbose logging
/// - `FUZZ_DURATION=N`: Override max duration (seconds)
/// - `FUZZ_CORPUS_MODE=<mode>`: Suite-level override of `fuzz(...)` calls' persistence:
///   - `auto`: Replay corpus if it exists, otherwise fuzz (default)
///   - `refuzzreplace`: Force `.replace` — fuzz fresh, replacing existing corpus
///   - `refuzzextend`: Force `.extend` — load corpus as seeds, continue fuzzing
///   - `regressiononly`: Force every `fuzz(...)` call to a verify-only replay (no
///     plugins run, so it never explores); tests with no corpus are a no-op.
///     `regress(...)` calls always replay and ignore this variable.
///
/// Example usage:
/// ```bash
/// # Re-fuzz all tests, replacing existing corpora
/// FUZZ_CORPUS_MODE=refuzzreplace swift test
///
/// # Extend existing corpora with more fuzzing
/// FUZZ_CORPUS_MODE=refuzzextend FUZZ_ITERATIONS=50000 swift test
///
/// # Only run regression (CI mode)
/// FUZZ_CORPUS_MODE=regressiononly swift test
/// ```

extension FuzzEngineConfig {
    /// Create config from environment variables.
    public static func fromEnvironment() -> FuzzEngineConfig {
        @Dependency(\.environment) var environment
        let env = environment.environment()

        var config = FuzzEngineConfig()

        if let duration = env["FUZZ_DURATION"].flatMap(TimeInterval.init) {
            config.maxDuration = .seconds(duration)
        }

        if env["FUZZ_VERBOSE"] != nil {
            config.verbose = true
        }

        return config
    }
}
