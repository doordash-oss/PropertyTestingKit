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
    persistence: CorpusPersistence = .auto,
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
            persistence: persistence,
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
/// The engine is a pure fuzz runner — it never loads or saves a corpus. For tests that
/// exercise corpus modes/persistence, use `runFuzzWithMaxIterations` instead.
///
/// - Parameters:
///   - maxIterations: The maximum number of iterations to run before the clock triggers timeout.
///   - config: Optional custom config. If nil, uses default config with test clock duration.
///   - additionalSeeds: Additional seed values for fuzzing.
///   - test: The test closure to run for each input.
/// - Returns: The fuzz result containing corpus, failures, and stats.
func fuzzEngineWithMaxIterations<each Input: MutatorProviding & Codable & Sendable>(
    maxIterations: Int,
    config: FuzzEngineConfig? = nil,
    coverageStrategy: CoverageStrategyKind? = nil,
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
                verbose: $0.verbose,
                timeLimitCheckInterval: $0.timeLimitCheckInterval,
                coverageStrategy: effectiveStrategy
            )
        } ?? FuzzEngineConfig(
            maxDuration: .seconds(10),
            timeLimitCheckInterval: 1,
            coverageStrategy: effectiveStrategy
        )
        let mutators = (repeat (each Input).defaultMutator)
        let engine = FuzzEngine(
            mutators: repeat each mutators,
            config: effectiveConfig
        )
        // The engine runs exactly the seeds it's given — assemble the mutators' seed
        // values plus any caller-provided seeds, mirroring a fuzz campaign.
        let seeds = mutatorSeeds(mutators) + additionalSeeds
        // Create default plugin processor (mutation handler)
        let processor = PluginProcessor(plugins: [FuzzPlugin<repeat each Input>.mutation()])
        let processSyncPlugins: @Sendable (
            consuming SyncPluginEvent<repeat each Input>,
            (FuzzPluginAction<repeat each Input>) -> Void
        ) -> Void = { event, execute in
            processor.processSync(event: event, execute: execute)
        }
        let processAsyncPlugins: @Sendable (
            consuming AsyncPluginEvent<repeat each Input>,
            (FuzzPluginAction<repeat each Input>) -> Void
        ) async -> Void = { event, execute in
            await processor.processAsync(event: event, execute: execute)
        }
        return await engine.run(seeds: seeds, processSyncPlugins: processSyncPlugins, processAsyncPlugins: processAsyncPlugins) { input in
            defer {
                virtualTime.update { $0 += advancement }
            }
            try await test(input)
        }
    })
}

/// Runs a fuzz campaign (the `fuzz(...)` coordinator path) with a controlled number of
/// iterations using a test clock.
///
/// Use this (rather than `fuzzEngineWithMaxIterations`) for tests that exercise corpus
/// policy — persistence, load/save, and the `.auto` replay-if-exists branch — since
/// persistence lives in the coordinator, not the engine. For pure regression replay,
/// use `runReplayWithMaxIterations`.
func runFuzzWithMaxIterations<each Input: MutatorProviding & Codable & Sendable>(
    maxIterations: Int,
    corpusDir: URL,
    persistence: CorpusPersistence,
    coverageStrategy: CoverageStrategyKind = .alwaysInteresting,
    parallelism: Int = 1,
    makeHandlers: @escaping @Sendable () -> [FuzzPlugin<repeat each Input>] = { [.corpusMutation()] },
    additionalSeeds: [(repeat each Input)] = [],
    test: @escaping @Sendable ((repeat each Input)) async throws -> Void
) async -> FuzzResult<repeat each Input> {
    let advancement = 10.0 / Double(maxIterations)
    let testClock = TestClock()
    let virtualTime = SyncBox<TimeInterval>(0)
    let startDate = Date()
    return await withDependencies({
        $0.continuousClockClient = testClock
        $0.dateClient = DateClient(now: {
            startDate.addingTimeInterval(virtualTime.value)
        })
    }, operation: {
        await runFuzz(
            mutators: (repeat (each Input).defaultMutator),
            userSeeds: additionalSeeds,
            corpusDir: corpusDir,
            persistence: persistence,
            parallelism: parallelism,
            duration: .seconds(10),
            verbose: false,
            coverageStrategy: coverageStrategy,
            edgeHook: nil,
            projectPath: nil,
            sourceFileID: "PropertyTestingKitTests/TestHelpers.swift",
            sourceFilePath: "PropertyTestingKitTests/TestHelpers.swift",
            line: 1,
            makeHandlers: makeHandlers,
            test: { input in
                defer {
                    virtualTime.update { $0 += advancement }
                }
                try await test(input)
            }
        )
    })
}

/// Runs a regression replay (the `regress(...)` coordinator path) with a controlled
/// number of iterations using a test clock. Replays the saved corpus; no fuzzing.
func runReplayWithMaxIterations<each Input: MutatorProviding & Codable & Sendable>(
    maxIterations: Int,
    corpusDir: URL,
    makeHandlers: @escaping @Sendable () -> [AnalysisPlugin<repeat each Input>] = { [] },
    test: @escaping @Sendable ((repeat each Input)) async throws -> Void
) async -> FuzzResult<repeat each Input> {
    let advancement = 10.0 / Double(maxIterations)
    let testClock = TestClock()
    let virtualTime = SyncBox<TimeInterval>(0)
    let startDate = Date()
    return await withDependencies({
        $0.continuousClockClient = testClock
        $0.dateClient = DateClient(now: {
            startDate.addingTimeInterval(virtualTime.value)
        })
    }, operation: {
        await runReplay(
            mutators: (repeat (each Input).defaultMutator),
            corpusDir: corpusDir,
            duration: .seconds(10),
            verbose: false,
            projectPath: nil,
            sourceFileID: "PropertyTestingKitTests/TestHelpers.swift",
            sourceFilePath: "PropertyTestingKitTests/TestHelpers.swift",
            line: 1,
            plugins: makeHandlers,
            test: { input in
                defer {
                    virtualTime.update { $0 += advancement }
                }
                try await test(input)
            }
        )
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
    persistence: CorpusPersistence = .auto,
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
            persistence: persistence,
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

