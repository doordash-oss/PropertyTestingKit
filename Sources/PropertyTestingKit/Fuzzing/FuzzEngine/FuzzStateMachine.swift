//
//  FuzzStateMachine.swift
//  Copyright © 2026 DoorDash. All rights reserved.
//

import Foundation
import Dependencies
import DequeModule
import Testing

actor FuzzStateMachine<each Input: Codable & Sendable> {
    /// Type-erased mutator functions for input mutation and generation.
    typealias MutatorMutate = @Sendable ((repeat each Input)) -> [(repeat each Input)]
    typealias MutatorGenerate = @Sendable () -> (repeat each Input)

    private let plugins: [any FuzzPlugin]
    private var pluginCoordinator: PluginCoordinator<repeat each Input>?
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
        plugins: [any FuzzPlugin],
        config: FuzzEngineConfig,
        startTime: Date,
        randomInputGenerator: @escaping MutatorGenerate,
        mutationGenerator: @escaping MutatorMutate,
        test: @escaping @Sendable ((repeat each Input)) async throws -> Void,
    ) {
        let corpus = Self.fetchCorpus()

        // Caching the dateclient
        @Dependency(\.dateClient) var dateClient: DateClient
        self.dateClient = dateClient
        self.startTime = startTime
        self.seeds = seeds
        self.randomInputGenerator = randomInputGenerator
        self.plugins = plugins
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

        // Create and start the plugin coordinator with bidirectional messaging
        let coordinator = PluginCoordinator<repeat each Input>(
            plugins: plugins
        )
        pluginCoordinator = coordinator
        await coordinator.start()

        // Start a task to consume actions from the coordinator
        let actionConsumerTask = Task { [self] in
            // Use dequeue with yield to avoid blocking the cooperative pool
            while !coordinator.actionChannel.isClosed {
                if let action = coordinator.actionChannel.dequeue() {
                    await self.executeAction(action)
                } else {
                    await Task.yield()
                }
            }
            // Drain any remaining actions
            while let action = coordinator.actionChannel.dequeue() {
                await self.executeAction(action)
            }
        }

        coordinator.send(event: .start(
            .init(
                maxDuration: config.maxDuration,
                corpusMode: config.corpusMode
            )
        ))

        // Initialize pending inputs with seeds
        pendingInputs = Deque(seeds)

        // Setup for test execution
        let coverageCountersClient = Self.fetchCoverageCounters()
        let testWithIssueCapture = Self.captureIssues(
            sourceLocation: config.sourceLocation,
            test: test
        )
        let sourceLocation = config.sourceLocation

        // Simple fuzz loop - no workers, just iterate
        var iterationCount = 0
        var generatedCount = 0

        // Hoist measurement context creation outside the loop for performance.
        // This avoids millions of hash table insert/remove operations.
        let context = coverageCountersClient.beginMeasurement()
        defer { coverageCountersClient.endMeasurement(context) }

        while !Task.isCancelled && !halted {
            // Check time limit
            let elapsed = Duration.seconds(dateClient.now().timeIntervalSince(startTime))
            if elapsed >= config.maxDuration {
                haltReason = .timeLimit
                break
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
            coverageCountersClient.resetCoverage(context)

            // Run test with coverage measurement
            do {
                // Will throw if either the test throws or if it logs an Issue
                try await testWithIssueCapture(input)

                // Coverage snapshot may throw if coverage is unavailable
                // Use addIfInterestingSparse to avoid creating a Set when coverage isn't interesting
                var didAdd = false
                if let sparse = try? coverageCountersClient.snapshotCoveredArraysWithContext(context) {
                    didAdd = await corpus.addIfInterestingSparse(input, sparse)
                }

                // Fire-and-forget: submit event without blocking (no actor hop)
                coordinator.send(event: .iteration(
                    .init(discoveredNewCoverage: didAdd, input: input)
                ))
            } catch is CancellationError {
                // Allow clean exit on cancellation
                break
            } catch {
                // On failure, we need the full signature for recording
                let coverageSignature: CoverageSignature
                if let sparse = try? coverageCountersClient.snapshotCoveredArraysWithContext(context) {
                    coverageSignature = CoverageSignature(sparse: sparse)
                } else {
                    coverageSignature = CoverageSignature(edges: Set())
                }
                recordFailure(input: input, error: error)
                // Fire-and-forget: submit event without blocking (no actor hop)
                coordinator.send(event: .failureFound(
                    .init(
                        input: input,
                        test: testWithIssueCapture,
                        sourceLocation: sourceLocation,
                        coverageSignature: coverageSignature
                    )
                ))
            }
            iterationCount += 1
        }

        if config.verbose {
            print("[FUZZ] Fuzz loop finished: iterations=\(iterationCount), generated=\(generatedCount), halted=\(halted)")
        }

        let totalCoveredIndices = await corpus.totalCoverage().executedIndices
        coordinator.send(event: .end(
            .init(
                totalCoveredIndices: totalCoveredIndices,
                projectPath: config.projectPath,
                sourceLocation: config.sourceLocation
            )
        ))

        // Wait for all plugin events to be processed and actions to be produced
        await coordinator.closeAndAwaitCompletion()
        // Wait for all actions to be executed
        await actionConsumerTask.value

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
    private static func captureIssues(
        sourceLocation: SourceLocation,
        test: @escaping @Sendable ((repeat each Input)) async throws -> Void
    ) -> @Sendable ((repeat each Input)) async throws -> Void {
        { input in
            try await captureIssue {
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
    private func executeAction(_ action: FuzzPluginAction<repeat each Input>) async {
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
            await addToCorpus(
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

    private func addToCorpus(_ input: (repeat each Input), signature: CoverageSignature, type: CorpusEntryType, failureInfo: FailureInfo?) async {
        await corpus.add(input, signature, type, failureInfo)
    }
}

