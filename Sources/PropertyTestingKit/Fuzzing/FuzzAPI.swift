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

/// Run a coverage-guided fuzz test with explicit mutators.
///
/// This function combines property-based testing with coverage guidance:
/// 1. First run: Explores inputs to maximize code coverage, saves minimal corpus
/// 2. Subsequent runs: Replays saved corpus, re-fuzzes if coverage changes
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
///   - corpusMode: Controls corpus behavior. Use `.refuzzReplace` to start fresh,
///     `.refuzzExtend` to add to existing corpus, or `.auto` for default behavior.
///     Can also be set via `FUZZ_CORPUS_MODE` environment variable.
///   - parallelism: Number of parallel fuzz engines to run. Each engine runs
///     independently with its portion of seeds distributed round-robin.
///     Results are merged at the end. Defaults to the number of available processors.
///   - defaultBehaviorPlugins: Core plugins that define fuzzing behavior. Defaults to `MutationPlugin()`.
///   - plugins: Additional plugins to run alongside default behavior (e.g., `CoverageGapPlugin()`).
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
    corpusMode: CorpusMode? = nil,
    coverageStrategy: CoverageStrategyKind = .pathTrie,
    edgeHook: EdgeHook? = nil,
    parallelism: Int = ProcessInfo.processInfo.processorCount,
    makeHandlers: @escaping @Sendable () -> [FuzzPluginHandler<repeat each Input>] = { [.corpusMutation()] },
    filePath: StaticString = #filePath,
    function: StaticString = #function,
    line: Int = #line,
    test: @escaping @Sendable ((repeat each Input)) async throws -> Void
) async throws -> FuzzResult<repeat each Input> {
    return try await fuzzInternal(
        mutators: (repeat each mutators),
        seeds: seeds,
        duration: duration,
        corpusMode: corpusMode,
        coverageStrategy: coverageStrategy,
        edgeHook: edgeHook,
        parallelism: parallelism,
        makeHandlers: makeHandlers,
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
    corpusMode: CorpusMode?,
    coverageStrategy: CoverageStrategyKind,
    edgeHook: EdgeHook?,
    parallelism: Int,
    makeHandlers: @escaping @Sendable () -> [FuzzPluginHandler<repeat each Input>],
    filePath: StaticString,
    function: StaticString,
    line: Int,
    test: @escaping @Sendable ((repeat each Input)) async throws -> Void
) async throws -> FuzzResult<repeat each Input> {
    @Dependency(\.environment) var environment
    @Dependency(\.corpusPersistence) var corpusPersistence

    let testFilePath = String(describing: filePath)
    let verbose = environment.environment()["FUZZ_VERBOSE"] != nil
    let effectiveParallelism = max(1, parallelism)
    let corpusDir = corpusDirectory(filePath: filePath, function: function)
    let effectiveCorpusMode = corpusMode ?? CorpusMode.fromEnvironment()

    // Check if we should run regression (single engine with corpus)
    // Regression mode runs single-threaded to properly handle corpus loading
    let corpusExists = corpusPersistence.exists(corpusDir)
    let shouldRunRegression = corpusExists && (effectiveCorpusMode == .auto || effectiveCorpusMode == .regressionOnly)

    if shouldRunRegression || effectiveParallelism == 1 {
        // Single engine mode: create a fresh handler set for this engine.
        let processor = PluginHandlerProcessor(handlers: makeHandlers())
        let processSyncPlugins: @Sendable (consuming SyncPluginEvent<repeat each Input>, (FuzzPluginAction<repeat each Input>) -> Void) -> Void = {
            processor.processSync(event: $0, execute: $1)
        }
        let processAsyncPlugins: @Sendable (isolated (any Actor)?, consuming AsyncPluginEvent<repeat each Input>, (FuzzPluginAction<repeat each Input>) -> Void) async -> Void = {
            await processor.processAsync(isolation: $0, event: $1, execute: $2)
        }

        let config = FuzzEngineConfig(
            maxDuration: duration,
            verbose: verbose,
            corpusMode: corpusMode,
            projectPath: projectPath(from: filePath),
            coverageStrategy: coverageStrategy,
            edgeHook: edgeHook,
            fileID: testFilePath,
            filePath: testFilePath,
            line: line,
            column: 1
        )

        let engine = FuzzEngine<repeat each Input>(
            mutators: mutators,
            config: config,
            corpusDirectory: corpusDir
        )

        let result = await engine.run(additionalSeeds: seeds, processSyncPlugins: processSyncPlugins, processAsyncPlugins: processAsyncPlugins, test: test)

        return try reportFuzzResult(result, filePath: filePath, line: line)
    }

    // Parallel fuzz mode: run N engines and merge results
    if verbose {
        print("[Fuzz] Running \(effectiveParallelism) parallel fuzz engines")
    }

    // Distribute seeds round-robin across engines
    var distributedSeeds: [[(repeat each Input)]] = Array(repeating: [], count: effectiveParallelism)
    for (index, seed) in seeds.enumerated() {
        distributedSeeds[index % effectiveParallelism].append(seed)
    }

    // Create and run N engines in parallel. Each engine calls makeHandlers() to get
    // its own independent handler instances — handlers must never be shared across engines.
    let results = await withTaskGroup(of: FuzzResult<repeat each Input>.self) { group in
        for engineIndex in 0..<effectiveParallelism {
            let engineSeeds = distributedSeeds[engineIndex]
            group.addTask {
                // Fresh handlers per engine — no shared mutable state.
                let processor = PluginHandlerProcessor(handlers: makeHandlers())
                let processSyncPlugins: @Sendable (consuming SyncPluginEvent<repeat each Input>, (FuzzPluginAction<repeat each Input>) -> Void) -> Void = {
                    processor.processSync(event: $0, execute: $1)
                }
                let processAsyncPlugins: @Sendable (isolated (any Actor)?, consuming AsyncPluginEvent<repeat each Input>, (FuzzPluginAction<repeat each Input>) -> Void) async -> Void = {
                    await processor.processAsync(isolation: $0, event: $1, execute: $2)
                }

                let config = FuzzEngineConfig(
                    maxDuration: duration,
                    verbose: verbose,
                    corpusMode: .refuzzReplace, // Each engine fuzzes fresh
                    projectPath: projectPath(from: filePath),
                    coverageStrategy: coverageStrategy,
                    edgeHook: edgeHook,
                    fileID: testFilePath,
                    filePath: testFilePath,
                    line: line,
                    column: 1
                )

                let engine = FuzzEngine<repeat each Input>(
                    mutators: mutators,
                    config: config,
                    corpusDirectory: nil // Don't save individual engine corpora
                )

                return await engine.run(additionalSeeds: engineSeeds, processSyncPlugins: processSyncPlugins, processAsyncPlugins: processAsyncPlugins, test: test)
            }
        }

        var allResults: [FuzzResult<repeat each Input>] = []
        for await result in group {
            allResults.append(result)
        }
        return allResults
    }

    // Merge results from all engines
    let mergedResult = await mergeResults(results, verbose: verbose)

    // Save merged corpus
    if !mergedResult.corpus.entries.isEmpty {
        do {
            try corpusPersistence.save(mergedResult.corpus, to: corpusDir)
            if verbose {
                print("[Fuzz] Saved merged corpus to \(corpusDir.path)")
            }
        } catch {
            if verbose {
                print("[Fuzz] Failed to save corpus: \(error)")
            }
        }
    }

    return try reportFuzzResult(mergedResult, filePath: filePath, line: line)
}

/// Run a coverage-guided fuzz test using the type's default mutator.
///
/// This version uses the type's `MutatorProviding.defaultMutator` for each input type.
/// For custom mutation strategies, use `fuzz(using:seeds:...)` with explicit mutators.
///
/// - Parameters:
///   - seeds: Domain-specific seed values to guide the fuzzer.
///   - duration: Maximum fuzzing time in seconds (default: 60).
///   - corpusMode: Controls corpus behavior. Use `.refuzzReplace` to start fresh,
///     `.refuzzExtend` to add to existing corpus, or `.auto` for default behavior.
///     Can also be set via `FUZZ_CORPUS_MODE` environment variable.
///   - parallelism: Number of parallel fuzz engines to run. Defaults to processor count.
///   - defaultBehaviorPlugins: Core plugins that define fuzzing behavior. Defaults to `MutationPlugin()`.
///   - plugins: Additional plugins to run alongside default behavior (e.g., `CoverageGapPlugin()`).
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
    corpusMode: CorpusMode? = nil,
    coverageStrategy: CoverageStrategyKind = .pathTrie,
    edgeHook: EdgeHook? = nil,
    parallelism: Int = ProcessInfo.processInfo.processorCount,
    makeHandlers: @escaping @Sendable () -> [FuzzPluginHandler<repeat each Input>] = { [.corpusMutation()] },
    filePath: StaticString = #filePath,
    function: StaticString = #function,
    line: Int = #line,
    test: @escaping @Sendable ((repeat each Input)) async throws -> Void
) async throws -> FuzzResult<repeat each Input> {
    try await fuzz(
        using: repeat (each Input).defaultMutator,
        seeds: seeds,
        duration: duration,
        corpusMode: corpusMode,
        coverageStrategy: coverageStrategy,
        edgeHook: edgeHook,
        parallelism: parallelism,
        makeHandlers: makeHandlers,
        filePath: filePath,
        function: function,
        line: line,
        test: test
    )
}

// MARK: - Result Merging

/// Merges results from multiple parallel fuzz engines.
private func mergeResults<each Input: Codable & Sendable>(
    _ results: [FuzzResult<repeat each Input>],
    verbose: Bool
) async -> FuzzResult<repeat each Input> {
    guard let first = results.first else {
        return .empty
    }

    guard results.count > 1 else {
        return first
    }

    // Merge all failures
    var allFailures: [(input: (repeat each Input), error: Error, timeElapsed: TimeInterval)] = []
    for result in results {
        allFailures.append(contentsOf: result.failures)
    }

    // Merge all coverage changes
    var allCoverageChanges: [(input: (repeat each Input), expected: SparseCoverage, actual: SparseCoverage)] = []
    for result in results {
        allCoverageChanges.append(contentsOf: result.coverageChanges)
    }

    // Merge corpus: combine all entries, deduplicate by coverage
    // Note: Use explicit closures instead of keypaths to avoid Swift runtime crashes with parameter packs
    let mergedCorpus = mergeCorpusSnapshots(results.map { $0.corpus })

    // Merge stats: sum counts, take max duration
    let totalInputs = results.reduce(0) { $0 + $1.stats.totalInputs }
    let totalMutations = results.reduce(0) { $0 + $1.stats.mutations }
    let totalGenerations = results.reduce(0) { $0 + $1.stats.generations }
    let maxDuration = results.map { $0.stats.duration }.max() ?? 0

    // Determine stop reason - use timeLimit if any engine hit it
    let stopReason: FuzzStats.StopReason = results.contains { $0.stats.stopReason == .timeLimit }
        ? .timeLimit
        : (results.first?.stats.stopReason ?? .timeLimit)

    // Check if any was a regression run
    let wasRegression = results.contains { $0.wasRegression }

    let mergedStats = FuzzStats(
        totalInputs: totalInputs,
        mutations: totalMutations,
        generations: totalGenerations,
        duration: maxDuration,
        stopReason: stopReason,
        failures: allFailures.count
    )

    if verbose {
        print("[Fuzz] Merged \(results.count) engines: \(totalInputs) total inputs, \(allFailures.count) failures")
    }

    return FuzzResult(
        corpus: mergedCorpus,
        failures: allFailures,
        stats: mergedStats,
        wasRegression: wasRegression,
        coverageChanges: allCoverageChanges
    )
}

/// Merges multiple corpus snapshots into one, combining coverage.
private func mergeCorpusSnapshots<each Input: Codable & Sendable>(
    _ snapshots: [CorpusSnapshot<repeat each Input>]
) -> CorpusSnapshot<repeat each Input> {
    @Dependency(\.corpusRegistry) var corpusRegistry

    guard let first = snapshots.first else {
        return CorpusSnapshot<repeat each Input>(
            entries: [],
            coveredIndices: []
        )
    }

    guard snapshots.count > 1 else {
        return first
    }

    // Create a temporary corpus to deduplicate entries
    let mergedCorpus: Corpus<repeat each Input> = corpusRegistry.getCorpus()

    // Use a local signature hash set for deduplication
    var signatureHashes = Set<Int>()

    // Add all entries - addIfInteresting handles deduplication by coverage
    for snapshot in snapshots {
        for entry in snapshot.entries {
            _ = mergedCorpus.addIfInteresting(input: entry.input, sparse: entry.sparseCoverage, signatureHashes: &signatureHashes)
        }
    }

    return mergedCorpus.snapshot()
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
/// - `FUZZ_CORPUS_MODE=<mode>`: Control corpus behavior for all tests:
///   - `auto`: Run regression if corpus exists, otherwise fuzz (default)
///   - `refuzzreplace`: Always fuzz fresh, replace existing corpus
///   - `refuzzextend`: Load corpus as seeds, continue fuzzing to find more
///   - `regressiononly`: Only run regression, skip tests with no corpus
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
