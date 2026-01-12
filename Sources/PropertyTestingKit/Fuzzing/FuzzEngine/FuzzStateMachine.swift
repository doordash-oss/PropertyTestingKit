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
    let inputQueue: TestInputQueue<repeat each Input>
    let outputQueue: TestOutputQueue<repeat each Input>
    lazy let workerPool: WorkerPool<repeat each Input>
    let pluginDispatcher: EventBasedPluginDispatcher
    let config: FuzzEngine.Config
    let corpus: CorpusClient<repeat each Input>
    let mutationGenerator: @Sendable (repeat each Input) -> [(repeat each Input)]

    init(
        seeds: [(repeat each Input)],
        pluginDispatcher: EventBasedPluginDispatcher,
        config: FuzzEngine<repeat each Input>.Config,
        startTime: Date,
        randomInputGenerator: @escaping @Sendable () -> (repeat each Input),
        mutationGenerator: @escaping @Sendable ((repeat each Input)) -> [(repeat each Input)],
        test: @escaping ((repeat each Input)) async throws -> Void,
    ) async throws {
        let inputQueue = TestInputQueue(
            initialValues: seeds,
            randomInputGenerator: randomInputGenerator
        )
        let outputQueue = TestOutputQueue<repeat each Input>()
        let corpus = Self.fetchCorpus()
        let coverageCountersClient = Self.fetchCoverageCounters()
        let testWithIssueCapture = Self.captureIssues(test: test)
        let startTime =

        self.outputQueue = outputQueue
        self.inputQueue = inputQueue
        self.pluginDispatcher = pluginDispatcher
        self.config = config
        self.corpus = corpus
        self.mutationGenerator = mutationGenerator

        self.workerPool = WorkerPool(
            inputQueue: inputQueue,
            test: { testInput, pool in
                // Check for halting conditions

                let context = coverageClient.beginMeasurement()
                do {
                    // Will throw if either the test throws or if it logs an Issue
                    try await testWithIssueCapture(testInput)

                    let coverageSignature = CoverageSignature(
                        sparse: coverageCountersClient.snapshotCoveredArraysWithContext(context)
                    )
                    let didAdd = corpus.addIfInteresting(testInput, coverageSignature)

                    try! await submitPluginEvent(.iteration(
                        .init(discoveredNewCoverage: didAdd)
                    ))
                } catch {
                    let coverageSignature = CoverageSignature(
                        sparse: coverageCountersClient.snapshotCoveredArraysWithContext(context)
                    )
                    try! await submitPluginEvent(.failureFound(
                        .init(
                            input: testInput,
                            test: testWithIssueCapture,
                            sourceLocation: config.sourceLocation,
                            coverageSignature: coverageSignature
                        )
                    ))
                }
                coverageClient.endMeasurement(context)
            },
            onComplete: {
                try await submitPluginEvent(.end(
                    .init(
                        totalCoveredIndices: corpus.totalCoverage().executedIndices,
                        projectPath: config.projectPath,
                        sourceLocation: config.sourceLocation
                    )
                ))
            }
        )

        try await submitPluginEvent(.start(
            .init(
                maxIterations: config.maxIterations,
                maxDuration: config.maxDuration,
                corpusMode: config.corpusMode
            )
        ))
    }

    func haltIfAtLimit(startTime: Date) {
        @Dependency var dateClient: DateClient

        if Duration.seconds(dateClient.now().timeIntervalSince(startTime)) >= config.maxDuration {
            if config.verbose {
                print("[Fuzz] Time limit reached after \(iteration) iterations")
            }

            workerPool.halt(reason: .timeLimit)
        }
    }

    func waitForCompletion() async throws {
        workerPool.poolTask?.value
    }

    /// Takes a test case and throws an error if any expectations failed
    static func captureIssues(
        test: @escaping (repeat each Input) async throws -> Void
    ) -> (repeat each Input) async throws -> Void {
        { input in
            var isError = false
            try await withKnownIssue(
                isIntermittent: true,
                sourceLocation: sourceLocation,
                { try await test(input) },
                matching: { issue in
                    Issue.record(issue.error, issue.comment, sourceLocation: issue.sourceLocation)
                    isError = true
                }
            )

            if isError {
                throw Errors.testFailed
            }
        }
    }

    static func fetchCorpus() -> CorpusClient<repeat each Input> {
        @Dependency(\.corpusRegistry) var corpusRegistry
        let schemaVersion = CorpusSchema.currentVersion()
        return corpusRegistry.get(schemaVersion: schemaVersion)
    }

    static func fetchCoverageCounters() -> CoverageCountersClient {
        @Dependency(\.coverageCounters) var coverageCounters
        return coverageCounters
    }

    /// Dispatches events to plugins and executes returned actions
    func submitPluginEvent(_ event: PluginEvent<repeat each Input>) async throws {
        try await execute(pluginDispatcher.dispatch(event))
    }

    func execute(
        _ actions: [FuzzPluginAction<repeat each Input>]
    ) {
        for action in actions {
            switch action {
            case .stop(let stopAction):
                workerPool.halt(reason: stopAction.reason)

            case .recordIssue(let issueAction):
                Issue.record(issueAction.comment, sourceLocation: issueAction.sourceLocation)

            case .queueInputs(let queueAction):
                inputQueue.push(contentsOf: queueAction.inputs)

            case .selectForMutation(let mutationAction):
                let mutations = mutationGenerator(mutationAction.input)
                inputQueue.push(contentsOf: mutations)

            case .submitToCorpus(let corpusAction):
                corpus.add(corpusAction.input)
            }
        }

        return result
    }
}

extension FuzzStateMachine {
    enum Errors: Error {
        case testFailed
    }
}

actor TestInputQueue<each Input> {
    var queue: Deque<(repeat each Input)>
    let randomInputGenerator: () -> (repeat each Input)

    init(initialValues: [(repeat each Input)] = [], randomInputGenerator: @escaping () -> (repeat each Input)) {
        self.queue = Deque(initialValues)
        self.randomInputGenerator = randomInputGenerator
    }

    func pull() -> (repeat each Input) {
        return queue.popFirst() ?? randomInputGenerator()
    }

    func push(_ element: repeat each Input) {
        queue.append((repeat each element))
    }

    func push(contentsOf collection: [(repeat each Input)]) {
        queue.append(contentsOf: collection)
    }
}

actor TestOutputQueue<each Input> {
    var queue: Deque<TestResult<repeat each Input>>

    init() {
        self.queue = Deque()
    }

    func pull() -> (repeat each Input) {
        return queue.popFirst()
    }

    func push(_ element: TestResult<repeat each Input>) {
        queue.append(element)
    }
}

/// Pool that uses a pull system to request tasks on completion
actor WorkerPool<each Input> {
    let size: Int
    let inputQueue: TestInputQueue<repeat each Input>
    let test: (repeat each Input) async throws -> Void
    let onComplete: (FuzzStats.StopReason) -> Void
    private lazy var poolTask: Task<Void, any Error>

    init(
        size: Int = ProcessInfo.processInfo.processorCount,
        inputQueue: TestInputQueue<repeat each Input>,
        test: @escaping (repeat each Input, Self) async throws -> Void,
        onComplete: @escaping (FuzzStats.StopReason) -> Void
    ) {
        // Workers at least 1
        let size = max(1, size)
        self.size = size
        self.inputQueue = inputQueue
        self.onComplete = onComplete

        self.poolTask = createPoolTask()
    }

    deinit {
        poolTask?.cancel()
    }

    private func createPoolTask() -> Task<Void, any Error> {
        Task {
            try await withThrowingTaskGroup { group in
                for _ in 0..<self.size {
                    group.addTask {
                        while !Task.isCancelled {
                            let input = inputQueue.pull()
                            try await self.test(input, self)
                        }
                    }
                }

                try await group.waitForAll()
            }
        }
    }

    func halt(reason: FuzzStats.StopReason) {
        poolTask?.cancel()
        _ = await poolTask?.value
        onComplete(reason: reason)
    }
}
