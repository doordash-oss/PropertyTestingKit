//
//  FuzzStateMachine.swift
//  Copyright © 2026 DoorDash. All rights reserved.
//

import Foundation
import DequeModule
import Dependencies
import Testing

// TODO: Create a new plugin that selects failed input for mutation
// add it to the list of plugins by default. It will simplify logic.
// have a list of base plugins with some defaults. Separate param from
// user selected plugins.

actor FuzzStateMachine<each Input: Codable & Sendable> {
    private let inputQueue: TestInputQueue<repeat each Input>
    private var workerPool: WorkerPool<repeat each Input>?
    private var pluginDispatcher: EventBasedPluginDispatcher
    private let config: FuzzEngine<repeat each Input>.Config
    private let corpus: CorpusClient<repeat each Input>
    private let mutationGenerator: @Sendable ((repeat each Input)) -> [(repeat each Input)]
    private let startTime: Date
    private let dateClient: DateClient
    private var failures: [(input: (repeat each Input), error: Error)] = []
    private let test: @Sendable ((repeat each Input)) async throws -> Void

    private var mutationsCount: Int = 0

    init(
        seeds: [(repeat each Input)],
        pluginDispatcher: EventBasedPluginDispatcher,
        config: FuzzEngine<repeat each Input>.Config,
        startTime: Date,
        randomInputGenerator: @escaping @Sendable () -> (repeat each Input),
        mutationGenerator: @escaping @Sendable ((repeat each Input)) -> [(repeat each Input)],
        test: @escaping @Sendable ((repeat each Input)) async throws -> Void,
    ) {
        let inputQueue = TestInputQueue(
            initialValues: seeds,
            randomInputGenerator: randomInputGenerator
        )
        let corpus = Self.fetchCorpus()

        // Caching the dateclient
        @Dependency(\.dateClient) var dateClient: DateClient
        self.dateClient = dateClient
        self.startTime = startTime
        self.inputQueue = inputQueue
        self.pluginDispatcher = pluginDispatcher
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

    private func setupWorkerPool() {
        let coverageCountersClient = Self.fetchCoverageCounters()
        let testWithIssueCapture = Self.captureIssues(
            sourceLocation: config.sourceLocation,
            test: test
        )

        // TODO: Avoid reference cycle
        self.workerPool = WorkerPool(
            inputQueue: inputQueue,
            test: { testInput in
                // Check for halting conditions
                await self.haltIfAtLimit(startTime: self.startTime)

                let context = coverageCountersClient.beginMeasurement()
                do {
                    // Will throw if either the test throws or if it logs an Issue
                    try await testWithIssueCapture(testInput)

                    let coverageSignature = CoverageSignature(
                        sparse: try coverageCountersClient.snapshotCoveredArraysWithContext(context)
                    )
                    let didAdd = await self.corpus.addIfInteresting(testInput, coverageSignature)

                    try! await self.submitPluginEvent(.iteration(
                        .init(discoveredNewCoverage: didAdd)
                    ))
                } catch {
                    let coverageSignature = CoverageSignature(
                        sparse: try! coverageCountersClient.snapshotCoveredArraysWithContext(context)
                    )
                    await self.addNewFailure((testInput, error))
                    try! await self.submitPluginEvent(.failureFound(
                        .init(
                            input: testInput,
                            test: testWithIssueCapture,
                            sourceLocation: self.config.sourceLocation,
                            coverageSignature: coverageSignature
                        )
                    ))
                }
                coverageCountersClient.endMeasurement(context)
            }
        )
    }

    func start() async throws -> FuzzStateMachineResult {
        setupWorkerPool()
        try await submitPluginEvent(.start(
            .init(
                maxDuration: config.maxDuration,
                corpusMode: config.corpusMode
            )
        ))

        guard let workerPool else {
            fatalError()
        }

        let result = try await workerPool.work()

        try await submitPluginEvent(.end(
            .init(
                totalCoveredIndices: corpus.totalCoverage().executedIndices,
                projectPath: config.projectPath,
                sourceLocation: config.sourceLocation
            )
        ))

        let stats = await FuzzStats(
            totalInputs: result.iterationCount,
            mutations: mutationsCount,
            generations: inputQueue.generatedCount,
            duration: startTime.distance(to: dateClient.now()),
            stopReason: result.stopReason,
            failures: failures.count
        )

        return FuzzStateMachineResult(
            stats: stats,
            corpus: corpus,
            failures: failures
        )
    }

    private func haltIfAtLimit(startTime: Date) async {
        if Duration.seconds(dateClient.now().timeIntervalSince(startTime)) >= config.maxDuration {
            await workerPool!.halt(reason: .timeLimit)
        }
    }

    /// Takes a test case and throws an error if any expectations failed
    private static func captureIssues(
        sourceLocation: SourceLocation,
        test: @escaping @Sendable ((repeat each Input)) async throws -> Void
    ) -> @Sendable ((repeat each Input)) async throws -> Void {
        { input in
            let issueRecorded = SyncBox(false)
            try await withKnownIssue(
                isIntermittent: true,
                sourceLocation: sourceLocation,
                { try await test(input) },
                matching: { issue in
                    let comment = Comment.init(rawValue: issue.comments.map { $0.rawValue }.joined())
                    if let error = issue.error {
                        if let sourceLocation = issue.sourceLocation {
                            Issue
                                .record(
                                    error,
                                    comment,
                                    sourceLocation: sourceLocation
                                )
                        } else {
                            Issue.record(error, comment)
                        }

                    } else {
                        if let sourceLocation = issue.sourceLocation {
                            Issue.record(comment, sourceLocation: sourceLocation)
                        } else {
                            Issue.record(comment)
                        }
                    }

                    issueRecorded.value = true

                    return true
                }
            )

            if issueRecorded.value {
                throw Errors.testFailed
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

    /// Dispatches events to plugins and executes returned actions
    private func submitPluginEvent(_ event: PluginEvent<repeat each Input>) async throws {
        try await execute(pluginDispatcher.dispatch(event: event))
    }

    private func execute(
        _ actions: [FuzzPluginAction<repeat each Input>]
    ) async {
        for action in actions {
            switch action {
            case .stop(let stopAction):
                await workerPool!.halt(reason: stopAction.reason)

            case .recordIssue(let issueAction):
                Issue.record(issueAction.comment, sourceLocation: issueAction.sourceLocation)

            case .queueInputs(let queueAction):
                await appendToInputs(queueAction.inputs)

            case .selectForMutation(let mutationAction):
                let mutations = mutationGenerator(mutationAction.input)
                await appendToInputs(mutations)
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
    }

    private func appendToInputs(_ inputs: [(repeat each Input)]) async {
        await inputQueue.push(contentsOf: inputs)
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

actor TestInputQueue<each Input: Sendable> {
    var queue: Deque<(repeat each Input)>
    let randomInputGenerator: () -> (repeat each Input)
    fileprivate var generatedCount: Int = 0

    init(initialValues: [(repeat each Input)] = [], randomInputGenerator: @escaping () -> (repeat each Input)) {
        self.queue = Deque(initialValues)
        self.randomInputGenerator = randomInputGenerator
    }

    func pull() -> sending (repeat each Input) {
        if let next = queue.popFirst() {
            return next
        } else {
            generatedCount += 1
            return randomInputGenerator()
        }
    }

    func push(_ element: repeat each Input) {
        queue.append((repeat each element))
    }

    func push(contentsOf collection: [(repeat each Input)]) {
        queue.append(contentsOf: collection)
    }
}

/// Pool that uses a pull system to request tasks on completion
actor WorkerPool<each Input: Sendable> {
    let size: Int
    let inputQueue: TestInputQueue<repeat each Input>
    let test: @Sendable ((repeat each Input)) async throws -> Void
    private var poolTask: Task<Void, any Error>?
    private var stopReason: FuzzStats.StopReason?

    private var processCount = 0

    init(
        size: Int = ProcessInfo.processInfo.processorCount,
        inputQueue: TestInputQueue<repeat each Input>,
        test: @escaping @Sendable ((repeat each Input)) async throws -> Void,
    ) {
        // Workers at least 1
        let size = max(1, size)
        self.size = size
        self.inputQueue = inputQueue
        self.test = test
    }

    deinit {
        stopReason = .custom("worker_pool_deinit")
        poolTask?.cancel()
    }

    // TODO: Avoid reference cycle
    func work() async throws -> WorkerPoolResult {
        poolTask = Task {
            try await withThrowingTaskGroup { group in
                for _ in 0..<self.size {
                    group.addTask {
                        while !Task.isCancelled {
                            let input = await self.inputQueue.pull()
                            try await self.test(input)
                            await self.incrementProcessCount()
                        }
                    }
                }

                try await group.waitForAll()
            }
        }

        _ = await poolTask?.result
        return WorkerPoolResult(
            iterationCount: processCount,
            stopReason: stopReason ?? FuzzStats.StopReason.timeLimit
        )
    }

    func halt(reason: FuzzStats.StopReason) {
        stopReason = reason
        poolTask?.cancel()
    }

    func incrementProcessCount() {
        processCount += 1
    }

    struct WorkerPoolResult {
        let iterationCount: Int
        let stopReason: FuzzStats.StopReason
    }
}
