//
//  FuzzStateMachine.swift
//  Copyright © 2026 DoorDash. All rights reserved.
//

import Foundation
import Dependencies
import Testing

// TODO: Create a new plugin that selects failed input for mutation
// add it to the list of plugins by default. It will simplify logic.
// have a list of base plugins with some defaults. Separate param from
// user selected plugins.

actor FuzzStateMachine<each Input: Codable & Sendable> {
    private var workerPool: WorkerPool<repeat each Input>?
    private let plugins: [any FuzzPlugin]
    private var pluginCoordinator: PluginCoordinator<repeat each Input>?
    private let config: FuzzEngine<repeat each Input>.Config
    private let corpus: CorpusClient<repeat each Input>
    private let mutationGenerator: @Sendable ((repeat each Input)) -> [(repeat each Input)]
    private let randomInputGenerator: @Sendable () -> (repeat each Input)
    private let seeds: [(repeat each Input)]
    private let startTime: Date
    private let dateClient: DateClient
    private var failures: [(input: (repeat each Input), error: Error)] = []
    private let test: @Sendable ((repeat each Input)) async throws -> Void

    private var mutationsCount: Int = 0

    init(
        seeds: [(repeat each Input)],
        plugins: [any FuzzPlugin],
        config: FuzzEngine<repeat each Input>.Config,
        startTime: Date,
        randomInputGenerator: @escaping @Sendable () -> (repeat each Input),
        mutationGenerator: @escaping @Sendable ((repeat each Input)) -> [(repeat each Input)],
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

    func addNewFailure(_ failure: (input: (repeat each Input), error: Error)) {
        failures.append(failure)
    }

    struct FuzzStateMachineResult {
        let stats: FuzzStats
        let corpus: CorpusClient<repeat each Input>
        let failures: [(input: (repeat each Input), error: Error)]
    }

    private func setupWorkerPool(coordinator: PluginCoordinator<repeat each Input>) {
        let coverageCountersClient = Self.fetchCoverageCounters()
        let testWithIssueCapture = Self.captureIssues(
            sourceLocation: config.sourceLocation,
            test: test
        )
        let sourceLocation = config.sourceLocation

        // TODO: Avoid reference cycle
        self.workerPool = WorkerPool(
            verbose: config.verbose,
            seeds: seeds,
            randomInputGenerator: randomInputGenerator,
            test: { testInput in
                // Check for halting conditions
                await self.haltIfAtLimit(startTime: self.startTime)

                let context = coverageCountersClient.beginMeasurement()
                do {
                    // Will throw if either the test throws or if it logs an Issue
                    try await testWithIssueCapture(testInput)

                    // Coverage snapshot may throw if coverage is unavailable - use empty signature
                    let coverageSignature: CoverageSignature
                    if let sparse = try? coverageCountersClient.snapshotCoveredArraysWithContext(context) {
                        coverageSignature = CoverageSignature(sparse: sparse)
                    } else {
                        coverageSignature = CoverageSignature(edges: Set())
                    }
                    let didAdd = await self.corpus.addIfInteresting(testInput, coverageSignature)

                    // Fire-and-forget: submit event without blocking (no actor hop)
                    coordinator.send(event: .iteration(
                        .init(discoveredNewCoverage: didAdd, input: testInput)
                    ))
                } catch is CancellationError {
                    // Re-throw cancellation to allow worker to exit cleanly
                    throw CancellationError()
                } catch {
                    // On failure, try to get coverage but use empty signature if unavailable
                    let coverageSignature: CoverageSignature
                    if let sparse = try? coverageCountersClient.snapshotCoveredArraysWithContext(context) {
                        coverageSignature = CoverageSignature(sparse: sparse)
                    } else {
                        coverageSignature = CoverageSignature(edges: Set())
                    }
                    await self.addNewFailure((testInput, error))
                    // Fire-and-forget: submit event without blocking (no actor hop)
                    coordinator.send(event: .failureFound(
                        .init(
                            input: testInput,
                            test: testWithIssueCapture,
                            sourceLocation: sourceLocation,
                            coverageSignature: coverageSignature
                        )
                    ))
                }
                coverageCountersClient.endMeasurement(context)
            }
        )
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
            // Use tryRecv with yield to avoid blocking the cooperative pool
            while !coordinator.actions.isClosed {
                if let action = coordinator.actions.tryRecv() {
                    await self.executeAction(action)
                } else {
                    await Task.yield()
                }
            }
            // Drain any remaining actions
            while let action = coordinator.actions.tryRecv() {
                await self.executeAction(action)
            }
        }

        setupWorkerPool(coordinator: coordinator)
        coordinator.send(event: .start(
            .init(
                maxDuration: config.maxDuration,
                corpusMode: config.corpusMode
            )
        ))

        guard let workerPool else {
            fatalError()
        }

        let result = try await workerPool.work()

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
            totalInputs: result.iterationCount,
            mutations: mutationsCount,
            generations: result.generatedCount,
            duration: startTime.distance(to: dateClient.now()),
            stopReason: result.stopReason,
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

    private func haltIfAtLimit(startTime: Date) async {
        let elapsed = Duration.seconds(dateClient.now().timeIntervalSince(startTime))
        if elapsed >= config.maxDuration {
            if config.verbose {
                print("[FUZZ] haltIfAtLimit: elapsed=\(elapsed), maxDuration=\(config.maxDuration) -> HALTING")
            }
            workerPool?.halt(reason: .timeLimit)
        }
    }

    /// Takes a test case and throws an error if any expectations failed.
    /// Uses `withKnownIssue` to intercept `#expect` failures without recording them.
    /// Thrown errors are caught inside the body to prevent `withKnownIssue` from logging them.
    private static func captureIssues(
        sourceLocation: SourceLocation,
        test: @escaping @Sendable ((repeat each Input)) async throws -> Void
    ) -> @Sendable ((repeat each Input)) async throws -> Void {
        { input in
            let capturedIssue = SyncBox<(any Error)?>(nil)
            let thrownError = SyncBox<(any Error)?>(nil)

            // Use withKnownIssue only for #expect failures.
            // Catch thrown errors inside the body to prevent withKnownIssue from logging them.
            await withKnownIssue(
                isIntermittent: true,
                sourceLocation: sourceLocation,
                {
                    do {
                        try await test(input)
                    } catch {
                        // Capture thrown error before withKnownIssue can log it
                        thrownError.value = error
                    }
                },
                matching: { issue in
                    // Capture #expect failures (first one wins)
                    if capturedIssue.value == nil {
                        capturedIssue.value = issue.error ?? Errors.testFailed
                    }
                    // Return true to suppress from test failure - we re-throw manually
                    return true
                }
            )

            // Re-throw captured errors (thrown error takes priority over #expect failure)
            if let error = thrownError.value {
                throw error
            }
            if let error = capturedIssue.value {
                throw error
            }
        }
    }

    private static func fetchCorpus() -> CorpusClient<repeat each Input> {
        @Dependency(\.corpusRegistry) var corpusRegistry
        let schemaVersion = CorpusSchema.currentVersion()
        return corpusRegistry.get(schemaVersion: schemaVersion)
    }

    private static func fetchCoverageCounters() -> CoverageCountersClient {
        @Dependency(\.coverageCounters) var coverageCounters
        return coverageCounters
    }

    /// Executes a single plugin action.
    private func executeAction(_ action: FuzzPluginAction<repeat each Input>) async {
        switch action {
        case .stop(let stopAction):
            workerPool?.halt(reason: stopAction.reason)

        case .recordIssue(let issueAction):
            Issue.record(issueAction.comment, sourceLocation: issueAction.sourceLocation)

        case .queueInputs(let queueAction):
            appendToInputs(queueAction.inputs)

        case .selectForMutation(let mutationAction):
            let mutations = mutationGenerator(mutationAction.input)
            appendToInputs(mutations)
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

    private func appendToInputs(_ inputs: [(repeat each Input)]) {
        workerPool?.pushInputs(inputs)
    }

    private func addToCorpus(_ input: (repeat each Input), signature: CoverageSignature, type: CorpusEntryType, failureInfo: FailureInfo?) async {
        await corpus.add(input, signature, type, failureInfo)
    }
}

extension FuzzStateMachine {
    enum Errors: Error {
        case testFailed
    }
}

import Atomics

/// Pool that distributes work to workers via per-worker channels.
///
/// Each worker has its own SPSC channel for receiving inputs. Workers pull
/// from their channel first; if empty, they generate random inputs locally.
/// This eliminates actor contention on the shared input queue.
final class WorkerPool<each Input: Sendable>: @unchecked Sendable {
    let size: Int
    let verbose: Bool
    let dispatcher: InputDispatcher<repeat each Input>
    let randomInputGenerator: @Sendable () -> (repeat each Input)
    let test: @Sendable ((repeat each Input)) async throws -> Void
    private var poolTask: Task<Void, any Error>?

    // Atomic counters for lock-free updates from workers
    private let _processCount: ManagedAtomic<Int>
    private let _generatedCount: ManagedAtomic<Int>
    private let _stopReason: ManagedAtomic<Int>  // 0 = none, 1 = timeLimit, 2+ = custom
    private let _halted: ManagedAtomic<Bool>

    var processCount: Int {
        _processCount.load(ordering: .relaxed)
    }

    var generatedCount: Int {
        _generatedCount.load(ordering: .relaxed)
    }

    init(
        size: Int = ProcessInfo.processInfo.processorCount,
        verbose: Bool = false,
        seeds: [(repeat each Input)] = [],
        randomInputGenerator: @escaping @Sendable () -> (repeat each Input),
        test: @escaping @Sendable ((repeat each Input)) async throws -> Void
    ) {
        // Workers at least 1
        let size = max(1, size)
        self.size = size
        self.verbose = verbose
        self.dispatcher = InputDispatcher(workerCount: size)
        self.randomInputGenerator = randomInputGenerator
        self.test = test
        self._processCount = ManagedAtomic(0)
        self._generatedCount = ManagedAtomic(0)
        self._stopReason = ManagedAtomic(0)
        self._halted = ManagedAtomic(false)

        // Distribute seeds round-robin to workers
        dispatcher.push(contentsOf: seeds)
    }

    /// Pushes inputs to be distributed to workers round-robin.
    func pushInputs(_ inputs: [(repeat each Input)]) {
        dispatcher.push(contentsOf: inputs)
    }

    func work() async throws -> WorkerPoolResult {
        if verbose {
            print("[FUZZ] WorkerPool.work() starting with size=\(size)")
        }
        let verboseCapture = verbose
        let randomInputGenerator = self.randomInputGenerator
        let test = self.test
        let processCountAtomic = _processCount
        let generatedCountAtomic = _generatedCount
        let haltedFlag = self._halted

        poolTask = Task {
            try await withThrowingTaskGroup { group in
                for workerIndex in 0..<self.size {
                    // Each worker gets their own channel - they don't see other workers' channels
                    let channel = self.dispatcher.channel(for: workerIndex)
                    group.addTask {
                        var iterationCount = 0
                        while !Task.isCancelled && !haltedFlag.load(ordering: .relaxed) {
                            // Try to pull from this worker's channel, generate random if empty
                            let input: (repeat each Input)
                            if let queued = channel.tryRecv() {
                                input = queued
                            } else {
                                input = randomInputGenerator()
                                generatedCountAtomic.wrappingIncrement(ordering: .relaxed)
                            }
                            try await test(input)
                            processCountAtomic.wrappingIncrement(ordering: .relaxed)
                            iterationCount += 1
                        }
                        if verboseCapture {
                            print("[FUZZ] Worker \(workerIndex) exiting: Task.isCancelled=\(Task.isCancelled), iterations=\(iterationCount)")
                        }
                    }
                }

                try await group.waitForAll()
            }
        }

        _ = await poolTask?.result
        let finalProcessCount = _processCount.load(ordering: .relaxed)
        if verbose {
            print("[FUZZ] WorkerPool.work() finished, processCount=\(finalProcessCount), stopReason=\(_stopReason.load(ordering: .relaxed))")
        }

        let stopReason: FuzzStats.StopReason
        switch _stopReason.load(ordering: .relaxed) {
        case 1:
            stopReason = .timeLimit
        case 2:
            stopReason = .custom("worker_pool_deinit")
        default:
            stopReason = .timeLimit
        }

        return WorkerPoolResult(
            iterationCount: finalProcessCount,
            generatedCount: _generatedCount.load(ordering: .relaxed),
            stopReason: stopReason
        )
    }

    func halt(reason: FuzzStats.StopReason) {
        // Set halted flag first so workers see it immediately
        _halted.store(true, ordering: .relaxed)

        if verbose {
            print("[FUZZ] WorkerPool.halt called with reason: \(reason), poolTask=\(poolTask != nil ? "present" : "nil")")
        }
        switch reason {
        case .timeLimit:
            _stopReason.store(1, ordering: .relaxed)
        default:
            _stopReason.store(2, ordering: .relaxed)
        }
        poolTask?.cancel()
        dispatcher.closeAll()
        if verbose {
            print("[FUZZ] WorkerPool.halt: cancel() called")
        }
    }

    struct WorkerPoolResult {
        let iterationCount: Int
        let generatedCount: Int
        let stopReason: FuzzStats.StopReason
    }
}
