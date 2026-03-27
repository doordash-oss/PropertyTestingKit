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

import Foundation
import Dependencies
import Testing
import ScheduleControl

/// Manages the fuzzing loop state. Not thread-safe - only used from a single task.
final class FuzzStateMachine<each Input: Codable & Sendable>: @unchecked Sendable {
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
    private var corpus: Corpus<repeat each Input>
    private let mutators: (repeat Mutator<each Input>)
    private let inputSize: Int
    private let seeds: [(repeat each Input)]
    private let startTime: Date
    private let dateClient: DateClient
    private var failures: [(input: (repeat each Input), error: Error, timeElapsed: TimeInterval)] = []
    private let test: @Sendable ((repeat each Input)) async throws -> Void

    private var mutationsCount: Int = 0

    /// The coverage strategy that determines interestingness.
    private let coverageStrategy: CoverageStrategy<repeat each Input>

    // Simple loop state (replaces WorkerPool)
    private var pendingInputs: SimpleRingBuffer<(repeat each Input)>
    /// Parallel to `pendingInputs` — schedule bytes for each pending input.
    /// Always kept in sync: append/remove both together.
    private var pendingScheduleBytes: SimpleRingBuffer<[UInt8]?>
    private var halted: Bool = false
    private var haltReason: FuzzStats.StopReason = .timeLimit

    init(
        seeds: [(repeat each Input)],
        mutators: (repeat Mutator<each Input>),
        inputSize: Int,
        corpus: Corpus<repeat each Input>,
        coverageStrategy: CoverageStrategy<repeat each Input>,
        processSyncPlugins: @escaping SyncPluginProcessorFn,
        processAsyncPlugins: @escaping AsyncPluginProcessorFn,
        config: FuzzEngineConfig,
        startTime: Date,
        test: @escaping @Sendable ((repeat each Input)) async throws -> Void
    ) {
        // Caching the dateclient
        @Dependency(\.dateClient) var dateClient: DateClient
        self.dateClient = dateClient
        self.startTime = startTime
        self.seeds = seeds
        self.mutators = mutators
        self.inputSize = inputSize
        self.coverageStrategy = coverageStrategy
        self.processSyncPlugins = processSyncPlugins
        self.processAsyncPlugins = processAsyncPlugins
        self.config = config
        self.corpus = corpus
        self.test = test
        self.pendingInputs = SimpleRingBuffer(minimumCapacity: 16)
        self.pendingScheduleBytes = SimpleRingBuffer(minimumCapacity: 16)
    }

    private func recordFailure(input: (repeat each Input), error: any Error) {
        failures.append((input: input, error: error, timeElapsed: startTime.distance(to: dateClient.now())))
    }

    struct FuzzStateMachineResult {
        let stats: FuzzStats
        let corpus: Corpus<repeat each Input>
        let failures: [(input: (repeat each Input), error: Error, timeElapsed: TimeInterval)]
    }

    func start() async throws -> FuzzStateMachineResult {
        if config.verbose {
            print("[FUZZ] FuzzStateMachine.start() called, maxDuration=\(config.maxDuration)")
        }

        // Initialize pending inputs with seeds
        pendingInputs = SimpleRingBuffer(seeds)
        pendingScheduleBytes = SimpleRingBuffer(seeds.map { _ in nil as [UInt8]? })

        // Setup for test execution
        let coverageCountersClient = Self.fetchCoverageCounters()
        let sourceLocation = config.sourceLocation

        // Cache RNG once here - passed to generate functions to avoid
        // dependency injection overhead per call (millions of calls).
        var rng = FastRNG()

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

            // Set up the coverage strategy before the first test execution.
            // pathTrie needs to attach its trie to the context so edges
            // advance the trie during the very first iteration.
            coverageStrategy.setup?(coverageContext)

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
                let currentScheduleBytes: [UInt8]?
                let fromMutationQueue: Bool
                if !pendingInputs.isEmpty {
                    input = pendingInputs.removeFirstUnchecked()
                    currentScheduleBytes = pendingScheduleBytes.removeFirstUnchecked()
                    fromMutationQueue = true
                } else {
                    // Generate directly - no closure indirection
                    input = (repeat (each mutators).generate(&rng))
                    currentScheduleBytes = config.scheduleFuzzing
                        ? (0..<64).map { _ in UInt8.random(in: 0...255, using: &rng) }
                        : nil
                    generatedCount += 1
                    fromMutationQueue = false
                }

                // Reset coverage for this iteration (cheap memset instead of hash table ops)
                coverageCountersClient.resetCoverage(coverageContext)

                // Run test with coverage measurement
                do {
                    // Will throw if either the test throws or if it logs an Issue
                    if let bytes = currentScheduleBytes {
                        try await ScheduleController.run(
                            scheduleBytes: bytes,
                            coverageContext: coverageContext.rawContext
                        ) {
                            try await testWithIssueCapture(input)
                        }
                    } else {
                        try await testWithIssueCapture(input)
                    }

                    // Delegate interestingness check to the coverage strategy
                    let didAdd = coverageStrategy.evaluate(
                        input,
                        currentScheduleBytes,
                        coverageContext,
                        coverageCountersClient,
                        corpus
                    )

                    // Snapshot coverage only when new edges were found — amortizes
                    // allocation cost since new coverage is rare (~0.1% of iterations).
                    let sparseCoverage: SparseCoverage? = didAdd
                        ? (try? coverageCountersClient.snapshotCoveredArraysWithContext(coverageContext))
                        : nil

                    // Process iteration event synchronously (hot path - no async)
                    processSyncPlugins(
                        .iteration(.init(
                            discoveredNewCoverage: didAdd,
                            input: input,
                            scheduleBytes: currentScheduleBytes,
                            fromMutationQueue: fromMutationQueue,
                            sparseCoverage: sparseCoverage
                        ))
                    ) { action in
                        self.executeAction(action)
                    }
                } catch is CancellationError {
                    // Allow clean exit on cancellation
                    break
                } catch {
                    // On failure, we need the sparse coverage for recording
                    let sparseCoverage: SparseCoverage
                    if let sparse = try? coverageCountersClient.snapshotCoveredArraysWithContext(coverageContext) {
                        sparseCoverage = sparse
                    } else {
                        sparseCoverage = SparseCoverage()
                    }
                    recordFailure(input: input, error: error)
                    // Process failure event asynchronously (cold path - async OK)
                    await processAsyncPlugins(
                        nil,
                        .failureFound(
                            .init(
                                input: input,
                                scheduleBytes: currentScheduleBytes,
                                test: testWithIssueCapture,
                                sourceLocation: sourceLocation,
                                sparseCoverage: sparseCoverage
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
            // Pad schedule bytes if shorter than inputs (defensive)
            let bytesCount = queueAction.scheduleBytes.count
            for i in 0..<queueAction.inputs.count {
                pendingScheduleBytes.append(i < bytesCount ? queueAction.scheduleBytes[i] : nil)
            }

        case .selectForMutation(let mutationAction):
            // Generate input mutations paired with original schedule bytes
            let inputMutations = generateMutations(mutationAction.input)
            for _ in inputMutations {
                pendingScheduleBytes.append(mutationAction.scheduleBytes)
            }
            pendingInputs.append(contentsOf: inputMutations)

            // Generate schedule byte mutations paired with original input
            if let bytes = mutationAction.scheduleBytes {
                let scheduleMutations = [UInt8].defaultMutator.mutate(bytes)
                for _ in scheduleMutations {
                    pendingInputs.append(mutationAction.input)
                }
                pendingScheduleBytes.append(contentsOf: scheduleMutations.map { $0 as [UInt8]? })
            }
            mutationsCount += 1

        case .submitToCorpus(let corpusAction):
            addToCorpus(
                corpusAction.input,
                scheduleBytes: corpusAction.scheduleBytes,
                sparse: corpusAction.sparseCoverage,
                type: corpusAction.entryType,
                failureInfo: corpusAction.failureInfo
            )
        }
    }

    private func halt(reason: FuzzStats.StopReason) {
        halted = true
        haltReason = reason
    }

    private func addToCorpus(_ input: (repeat each Input), scheduleBytes: [UInt8]? = nil, sparse: SparseCoverage, type: CorpusEntryType, failureInfo: FailureInfo?) {
        corpus.add(input: input, scheduleBytes: scheduleBytes, sparse: sparse, entryType: type, failure: failureInfo)
    }

    /// Generate mutations for an input by mutating one position at a time.
    /// Returns the cartesian product of mutations across all positions.
    private func generateMutations(_ input: (repeat each Input)) -> [(repeat each Input)] {
        let positionsMutated: [(repeat [each Input])] = (0..<inputSize).map { replacementIndex in
            var currentIndex = 0
            return (repeat {
                defer { currentIndex += 1 }
                if currentIndex == replacementIndex {
                    return (each mutators).mutate(each input)
                } else {
                    return [(each input)]
                }
            }())
        }
        return positionsMutated.flatMap(cartesianProduct)
    }
}

