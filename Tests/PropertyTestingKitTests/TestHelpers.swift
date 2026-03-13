//
//  TestHelpers.swift
//  PropertyTestingKitTests
//
//  Shared test utilities for PropertyTestingKit tests.
//

import Testing
import Foundation
import Clocks
import Dependencies
@testable import PropertyTestingKit

/// Runs a fuzz test with a controlled number of iterations using a test clock.
///
/// This helper advances a test clock after each iteration, making tests deterministic
/// and fast since they don't wait for real time to pass.
///
/// - Parameters:
///   - maxIterations: The maximum number of iterations to run before the clock triggers timeout.
///   - seeds: Initial seed values for fuzzing.
///   - duration: The virtual duration (defaults to 60 seconds, but clock is advanced to complete in maxIterations).
///   - corpusMode: How to handle existing corpus files.
///   - filePath: Source file path for error reporting.
///   - function: Function name for error reporting.
///   - line: Line number for error reporting.
///   - test: The test closure to run for each input.
/// - Returns: The fuzz result containing corpus, failures, and stats.
func fuzzWithMaxIterations<each Input: MutatorProviding & Codable & Sendable>(
    maxIterations: Int,
    seeds: [(repeat each Input)] = [],
    duration: Duration = .seconds(60),
    corpusMode: CorpusMode? = nil,
    coverageStrategy: CoverageStrategyKind = .signatureMatch,
    parallelism: Int = 1,
    filePath: StaticString = #filePath,
    function: StaticString = #function,
    line: Int = #line,
    test: @escaping @Sendable ((repeat each Input)) async throws -> Void
) async throws -> FuzzResult<repeat each Input> {
    let advancement = 10.0 / Double(maxIterations)
    let testClock = TestClock()
    // Track virtual time for DateClient (SyncBox for sync access from @Sendable closure)
    let virtualTime = SyncBox<TimeInterval>(0)
    let startDate = Date()
    return try await withDependencies({
        // FuzzEngine uses continuousClockClient for timeout
        $0.continuousClockClient = testClock
        // FuzzStateMachine uses dateClient to check elapsed time
        $0.dateClient = DateClient(now: {
            startDate.addingTimeInterval(virtualTime.value)
        })
    }, operation: {
        try await fuzz(
            seeds: seeds,
            duration: .seconds(10),
            corpusMode: corpusMode,
            coverageStrategy: coverageStrategy,
            parallelism: parallelism,
            filePath: filePath,
            function: function,
            line: line,
            test: { input in
                defer {
                    virtualTime.update { $0 += advancement }
                }
                try await test(input)
            }
        )
    })
}

/// Runs a FuzzEngine with a controlled number of iterations using a test clock.
///
/// This helper advances a test clock after each iteration, making tests deterministic
/// and fast since they don't wait for real time to pass.
///
/// - Parameters:
///   - maxIterations: The maximum number of iterations to run before the clock triggers timeout.
///   - config: Optional custom config. If nil, uses default config with test clock duration.
///   - corpusDirectory: Optional corpus directory for persistence.
///   - additionalSeeds: Additional seed values for fuzzing.
///   - test: The test closure to run for each input.
/// - Returns: The fuzz result containing corpus, failures, and stats.
func fuzzEngineWithMaxIterations<each Input: MutatorProviding & Codable & Sendable>(
    maxIterations: Int,
    config: FuzzEngineConfig? = nil,
    coverageStrategy: CoverageStrategyKind? = nil,
    corpusDirectory: URL? = nil,
    additionalSeeds: [(repeat each Input)] = [],
    test: @escaping @Sendable ((repeat each Input)) async throws -> Void
) async -> FuzzResult<repeat each Input> {
    let advancement = 10.0 / Double(maxIterations)
    let testClock = TestClock()
    // Track virtual time for DateClient (SyncBox for sync access from @Sendable closure)
    let virtualTime = SyncBox<TimeInterval>(0)
    let startDate = Date()
    return await withDependencies({
        // FuzzEngine uses continuousClockClient for timeout
        $0.continuousClockClient = testClock
        // FuzzStateMachine uses dateClient to check elapsed time
        $0.dateClient = DateClient(now: {
            startDate.addingTimeInterval(virtualTime.value)
        })
    }, operation: {
        // Use timeLimitCheckInterval: 1 for precise iteration control in tests
        let effectiveStrategy = coverageStrategy ?? config?.coverageStrategy ?? .signatureMatch
        let effectiveConfig = config.map {
            FuzzEngineConfig(
                maxDuration: $0.maxDuration,
                minimizeCorpus: $0.minimizeCorpus,
                verbose: $0.verbose,
                corpusMode: $0.corpusMode,
                timeLimitCheckInterval: $0.timeLimitCheckInterval,
                coverageStrategy: effectiveStrategy
            )
        } ?? FuzzEngineConfig(
            maxDuration: .seconds(10),
            timeLimitCheckInterval: 1,
            coverageStrategy: effectiveStrategy
        )
        let engine = FuzzEngine(
            mutators: (repeat (each Input).defaultMutator),
            config: effectiveConfig,
            corpusDirectory: corpusDirectory
        )
        // Create default plugin processor (mutation handler)
        let processor = PluginHandlerProcessor(handlers: [FuzzPluginHandler<repeat each Input>.mutation()])
        let processSyncPlugins: @Sendable (
            consuming SyncPluginEvent<repeat each Input>,
            (FuzzPluginAction<repeat each Input>) -> Void
        ) -> Void = { event, execute in
            processor.processSync(event: event, execute: execute)
        }
        let processAsyncPlugins: @Sendable (
            isolated (any Actor)?,
            consuming AsyncPluginEvent<repeat each Input>,
            (FuzzPluginAction<repeat each Input>) -> Void
        ) async -> Void = { isolation, event, execute in
            await processor.processAsync(isolation: isolation, event: event, execute: execute)
        }
        return await engine.run(additionalSeeds: additionalSeeds, processSyncPlugins: processSyncPlugins, processAsyncPlugins: processAsyncPlugins) { input in
            defer {
                virtualTime.update { $0 += advancement }
            }
            try await test(input)
        }
    })
}

/// Runs a fuzz test with custom mutators and a controlled number of iterations using a test clock.
///
/// This helper is for tests that use `fuzz(using:...)` with custom mutator strategies.
///
/// - Parameters:
///   - maxIterations: The maximum number of iterations to run before the clock triggers timeout.
///   - mutators: The custom mutators to use for fuzzing.
///   - seeds: Initial seed values for fuzzing.
///   - corpusMode: How to handle existing corpus files.
///   - filePath: Source file path for error reporting.
///   - function: Function name for error reporting.
///   - line: Line number for error reporting.
///   - test: The test closure to run for each input.
/// - Returns: The fuzz result containing corpus, failures, and stats.
func fuzzWithMaxIterations<each Input: Codable & Sendable>(
    maxIterations: Int,
    using mutators: repeat Mutator<each Input>,
    seeds: [(repeat each Input)] = [],
    corpusMode: CorpusMode? = nil,
    coverageStrategy: CoverageStrategyKind = .signatureMatch,
    parallelism: Int = 1,
    filePath: StaticString = #filePath,
    function: StaticString = #function,
    line: Int = #line,
    test: @escaping @Sendable ((repeat each Input)) async throws -> Void
) async throws -> FuzzResult<repeat each Input> {
    let advancement = 10.0 / Double(maxIterations)
    let testClock = TestClock()
    // Track virtual time for DateClient (SyncBox for sync access from @Sendable closure)
    let virtualTime = SyncBox<TimeInterval>(0)
    let startDate = Date()
    return try await withDependencies({
        // FuzzEngine uses continuousClockClient for timeout
        $0.continuousClockClient = testClock
        // FuzzStateMachine uses dateClient to check elapsed time
        $0.dateClient = DateClient(now: {
            startDate.addingTimeInterval(virtualTime.value)
        })
    }, operation: {
        try await fuzz(
            using: repeat each mutators,
            seeds: seeds,
            duration: .seconds(10),
            corpusMode: corpusMode,
            coverageStrategy: coverageStrategy,
            parallelism: parallelism,
            filePath: filePath,
            function: function,
            line: line,
            test: { input in
                defer {
                    virtualTime.update { $0 += advancement }
                }
                try await test(input)
            }
        )
    })
}
