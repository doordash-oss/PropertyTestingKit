//
//  FuzzStateMachine.swift
//  Copyright © 2026 DoorDash. All rights reserved.
//

import Foundation
import Dependencies
import DequeModule
import Testing

/// Manages the fuzzing loop state. Not thread-safe - only used from a single task.
final class FuzzStateMachine<each Input: Codable & Sendable>: @unchecked Sendable {
    /// Type-erased mutator functions for input mutation and generation.
    typealias MutatorMutate = @Sendable ((repeat each Input)) -> [(repeat each Input)]
    typealias MutatorGenerate = @Sendable () -> (repeat each Input)

    /// Synchronous plugin processor for iteration events (hot path).
    /// Captures concrete plugin types via closure; signature only mentions Input types.
    typealias SyncPluginProcessorFn = @Sendable (
        consuming SyncPluginEvent<repeat each Input>,
        (FuzzPluginAction<repeat each Input>) -> Void
    ) -> Void

    /// Asynchronous plugin processor for rare events (cold path).
    typealias AsyncPluginProcessorFn = @Sendable (
        isolated (any Actor)?,
        consuming AsyncPluginEvent<repeat each Input>,
        (FuzzPluginAction<repeat each Input>) -> Void
    ) async -> Void

    /// Sync plugin processor closure for iteration events.
    private let processSyncPlugins: SyncPluginProcessorFn
    /// Async plugin processor closure for rare events.
    private let processAsyncPlugins: AsyncPluginProcessorFn
    private let config: FuzzEngineConfig
    private let corpus: CorpusClient<repeat each Input>
    private let mutationGenerator: MutatorMutate
    private let randomInputGenerator: MutatorGenerate
    private let seeds: [(repeat each Input)]
    private let startTime: Date
    private let dateClient: DateClient
    private var failures: [(input: (repeat each Input), error: Error)] = []
    private let test: @Sendable ((repeat each Input)) async throws -> Void

    private var mutationsCount: Int = 0

    // Simple loop state (replaces WorkerPool)
    private var pendingInputs: Deque<(repeat each Input)> = []
    private var halted: Bool = false
    private var haltReason: FuzzStats.StopReason = .timeLimit

    init(
        seeds: [(repeat each Input)],
        processSyncPlugins: @escaping SyncPluginProcessorFn,
        processAsyncPlugins: @escaping AsyncPluginProcessorFn,
        config: FuzzEngineConfig,
        startTime: Date,
        randomInputGenerator: @escaping MutatorGenerate,
        mutationGenerator: @escaping MutatorMutate,
        test: @escaping @Sendable ((repeat each Input)) async throws -> Void
    ) {
        let corpus = Self.fetchCorpus()

        // Caching the dateclient
        @Dependency(\.dateClient) var dateClient: DateClient
        self.dateClient = dateClient
        self.startTime = startTime
        self.seeds = seeds
        self.randomInputGenerator = randomInputGenerator
        self.processSyncPlugins = processSyncPlugins
        self.processAsyncPlugins = processAsyncPlugins
        self.config = config
        self.corpus = corpus
        self.mutationGenerator = mutationGenerator
        self.test = test
    }

    private func recordFailure(input: (repeat each Input), error: any Error) {
        failures.append((input: input, error: error))
    }

    struct FuzzStateMachineResult {
        let stats: FuzzStats
        let corpus: CorpusClient<repeat each Input>
        let failures: [(input: (repeat each Input), error: Error)]
    }

    func start() async throws -> FuzzStateMachineResult {
        if config.verbose {
            print("[FUZZ] FuzzStateMachine.start() called, maxDuration=\(config.maxDuration)")
        }

        // Initialize pending inputs with seeds
        pendingInputs = Deque(seeds)

        // Setup for test execution
        let coverageCountersClient = Self.fetchCoverageCounters()
        let sourceLocation = config.sourceLocation

        // Simple fuzz loop - no workers, just iterate
        var iterationCount = 0
        var generatedCount = 0

        // Wrap entire loop in issue capture context to avoid per-iteration TaskLocal overhead.
        // This saves ~12s over millions of iterations by doing one TaskLocal push/pop instead of millions.
        await withIssueCaptureContext { issueCaptureContext in
            let testWithIssueCapture = Self.captureIssues(
                context: issueCaptureContext,
                sourceLocation: config.sourceLocation,
                test: test
            )

            // Hoist measurement context creation outside the loop for performance.
            // This avoids millions of hash table insert/remove operations.
            let coverageContext = coverageCountersClient.beginMeasurement()
            defer { coverageCountersClient.endMeasurement(coverageContext) }

            // Check time limit every N iterations to avoid per-iteration Date.init() overhead.
            // With ~10M iterations/sec and default interval of 1000, this means ~10K checks/sec.
            // The interval is configurable via FuzzEngineConfig for tests that need precise control.
            let timeLimitCheckInterval = config.timeLimitCheckInterval
            var iterationsSinceTimeCheck = timeLimitCheckInterval // Force check on first iteration

            while !Task.isCancelled && !halted {
                // Check time limit periodically (avoids ~3.5s overhead from per-iteration Date.init)
                iterationsSinceTimeCheck += 1
                if iterationsSinceTimeCheck >= timeLimitCheckInterval {
                    iterationsSinceTimeCheck = 0
                    // Yield to allow other tasks to run (enables parallel fuzz runs)
                    await Task.yield()
                    let elapsed = Duration.seconds(dateClient.now().timeIntervalSince(startTime))
                    if elapsed >= config.maxDuration {
                        haltReason = .timeLimit
                        break
                    }
                }

                // Get input: from pending queue or generate random
                let input: (repeat each Input)
                if !pendingInputs.isEmpty {
                    input = pendingInputs.removeFirst()
                } else {
                    input = randomInputGenerator()
                    generatedCount += 1
                }

                // Reset coverage for this iteration (cheap memset instead of hash table ops)
                coverageCountersClient.resetCoverage(coverageContext)

                // Run test with coverage measurement
                do {
                    // Will throw if either the test throws or if it logs an Issue
                    try await testWithIssueCapture(input)

                    // Coverage snapshot may throw if coverage is unavailable
                    // Use addIfInterestingSparse to avoid creating a Set when coverage isn't interesting
                    var didAdd = false
                    if let sparse = try? coverageCountersClient.snapshotCoveredArraysWithContext(coverageContext) {
                        didAdd = corpus.addIfInterestingSparse(input, sparse)
                    }

                    // Process iteration event synchronously (hot path - no async)
                    processSyncPlugins(
                        .iteration(.init(discoveredNewCoverage: didAdd, input: input))
                    ) { action in
                        self.executeAction(action)
                    }
                } catch is CancellationError {
                    // Allow clean exit on cancellation
                    break
                } catch {
                    // On failure, we need the full signature for recording
                    let coverageSignature: CoverageSignature
                    if let sparse = try? coverageCountersClient.snapshotCoveredArraysWithContext(coverageContext) {
                        coverageSignature = CoverageSignature(sparse: sparse)
                    } else {
                        coverageSignature = CoverageSignature(edges: Set())
                    }
                    recordFailure(input: input, error: error)
                    // Process failure event asynchronously (cold path - async OK)
                    await processAsyncPlugins(
                        nil,
                        .failureFound(
                            .init(
                                input: input,
                                test: testWithIssueCapture,
                                sourceLocation: sourceLocation,
                                coverageSignature: coverageSignature
                            )
                        )
                    ) { action in
                        self.executeAction(action)
                    }
                }
                iterationCount += 1
            }
        }

        if config.verbose {
            print("[FUZZ] Fuzz loop finished: iterations=\(iterationCount), generated=\(generatedCount), halted=\(halted)")
        }

        let stats = FuzzStats(
            totalInputs: iterationCount,
            mutations: mutationsCount,
            generations: generatedCount,
            duration: startTime.distance(to: dateClient.now()),
            stopReason: haltReason,
            failures: failures.count
        )

        if config.verbose {
            print("[FUZZ] FuzzStateMachine.start() finished: totalInputs=\(stats.totalInputs), duration=\(stats.duration), stopReason=\(stats.stopReason)")
        }
        return FuzzStateMachineResult(
            stats: stats,
            corpus: corpus,
            failures: failures
        )
    }

    /// Takes a test case and throws an error if any expectations failed.
    /// Uses lightweight issue detection to intercept `#expect` failures without
    /// the overhead of `withKnownIssue`.
    ///
    /// This version uses batched issue capture context to avoid per-iteration
    /// TaskLocal overhead (~12s savings over millions of iterations).
    private static func captureIssues(
        context: IssueCaptureContext,
        sourceLocation: SourceLocation,
        test: @escaping @Sendable ((repeat each Input)) async throws -> Void
    ) -> @Sendable ((repeat each Input)) async throws -> Void {
        { input in
            try await context.captureIssue {
                try await test(input)
            }
        }
    }

    private static func fetchCorpus() -> CorpusClient<repeat each Input> {
        @Dependency(\.corpusRegistry) var corpusRegistry
        return corpusRegistry.get()
    }

    private static func fetchCoverageCounters() -> CoverageCountersClient {
        @Dependency(\.coverageCounters) var coverageCounters
        return coverageCounters
    }

    /// Executes a single plugin action.
    private func executeAction(_ action: FuzzPluginAction<repeat each Input>) {
        switch action {
        case .stop(let stopAction):
            halt(reason: stopAction.reason)

        case .recordIssue(let issueAction):
            Issue.record(issueAction.comment, sourceLocation: issueAction.sourceLocation)

        case .queueInputs(let queueAction):
            pendingInputs.append(contentsOf: queueAction.inputs)

        case .selectForMutation(let mutationAction):
            let mutations = mutationGenerator(mutationAction.input)
            pendingInputs.append(contentsOf: mutations)
            mutationsCount += 1

        case .submitToCorpus(let corpusAction):
            addToCorpus(
                corpusAction.input,
                signature: corpusAction.coverageSignature,
                type: corpusAction.entryType,
                failureInfo: corpusAction.failureInfo
            )
        }
    }

    private func halt(reason: FuzzStats.StopReason) {
        halted = true
        haltReason = reason
    }

    private func addToCorpus(_ input: (repeat each Input), signature: CoverageSignature, type: CorpusEntryType, failureInfo: FailureInfo?) {
        corpus.add(input, signature, type, failureInfo)
    }
}

