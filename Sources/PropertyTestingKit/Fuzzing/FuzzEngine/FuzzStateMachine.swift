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

import Dependencies
import Foundation
import Testing
import SanCovHooks
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
    private var failures: [(input: (repeat each Input), error: Error, timeElapsed: TimeInterval, scheduleBytes: [UInt8]?)] =
        []
    private let test: @Sendable ((repeat each Input)) async throws -> Void

    /// Extracts the schedule bytes from an input. When schedule fuzzing over the
    /// flattened pack `([UInt8], repeat each UserInput)`, this returns element 0;
    /// for non-scheduled runs it returns `nil`. When non-nil, the test execution
    /// is wrapped in `ScheduleController.run` to fuzz task interleaving.
    private let scheduleBytesExtractor: @Sendable ((repeat each Input)) -> [UInt8]?

    /// Seed inputs executed. Seeds are enqueued before the loop starts and the
    /// queue is FIFO with mutations appended behind them, so the first
    /// `seeds.count` queue pops are exactly the seeds.
    private var seedsRunCount: Int = 0
    /// Mutated inputs executed (queue pops after the seeds drained).
    private var mutantsRunCount: Int = 0

    /// The coverage evaluator that determines interestingness.
    private let coverageEvaluator: CoverageEvaluator<repeat each Input>

    // Simple loop state (replaces WorkerPool)
    private var pendingInputs: SimpleRingBuffer<(repeat each Input)>
    /// Lineage tags in lockstep with `pendingInputs`: the `originID` of the
    /// `selectForMutation` action each queued mutant came from (`nil` for
    /// seeds and plain `queueInputs`). Kept as a parallel buffer because the
    /// input pack can't nest inside another tuple element cheaply.
    private var pendingParents: SimpleRingBuffer<Int?>
    private var haltReason: FuzzStats.StopReason?
    /// Scope of the halt that ended the loop. `.campaign` means a plugin asked to
    /// stop the whole parallel run, not just this engine.
    private var haltScope: StopScope = .engine

    init(
        seeds: [(repeat each Input)],
        mutators: (repeat Mutator<each Input>),
        inputSize: Int,
        corpus: Corpus<repeat each Input>,
        coverageEvaluator: CoverageEvaluator<repeat each Input>,
        processSyncPlugins: @escaping SyncPluginProcessorFn,
        processAsyncPlugins: @escaping AsyncPluginProcessorFn,
        config: FuzzEngineConfig,
        startTime: Date,
        test: @escaping @Sendable ((repeat each Input)) async throws -> Void,
        scheduleBytesExtractor: @escaping @Sendable ((repeat each Input)) -> [UInt8]?
    ) {
        // Caching the dateclient
        @Dependency(\.dateClient) var dateClient: DateClient
        self.dateClient = dateClient
        self.startTime = startTime
        self.seeds = seeds
        self.mutators = mutators
        self.inputSize = inputSize
        self.coverageEvaluator = coverageEvaluator
        self.processSyncPlugins = processSyncPlugins
        self.processAsyncPlugins = processAsyncPlugins
        self.config = config
        self.corpus = corpus
        self.test = test
        self.scheduleBytesExtractor = scheduleBytesExtractor
        self.pendingInputs = SimpleRingBuffer(minimumCapacity: 16)
        self.pendingParents = SimpleRingBuffer(minimumCapacity: 16)
    }

    private func recordFailure(input: (repeat each Input), error: any Error) {
        // `scheduleBytes` stays nil here: during schedule fuzzing the schedule is
        // input element 0, and `peelScheduleResult` lifts it onto this slot for the
        // user-facing result (mirroring how corpus entries are handled).
        failures.append(
            (input: input, error: error, timeElapsed: startTime.distance(to: dateClient.now()), scheduleBytes: nil))
    }

    struct FuzzStateMachineResult {
        let stats: FuzzStats
        let corpus: Corpus<repeat each Input>
        let failures: [(input: (repeat each Input), error: Error, timeElapsed: TimeInterval, scheduleBytes: [UInt8]?)]
        /// A plugin asked to stop the whole parallel campaign (`StopScope.campaign`).
        let campaignStopRequested: Bool
    }

    func start() async throws -> FuzzStateMachineResult {
        if config.verbose {
            print("[FUZZ] FuzzStateMachine.start() called, maxDuration=\(config.maxDuration)")
        }

        // Initialize pending inputs with seeds. Schedule bytes (when scheduling)
        // travel inside the input pack as element 0, so there is no parallel
        // schedule-bytes queue to seed — `scheduleBytesExtractor` reads them from
        // each input.
        pendingInputs = SimpleRingBuffer(seeds)
        pendingParents = SimpleRingBuffer(minimumCapacity: max(16, seeds.count))
        pendingParents.append(contentsOf: [Int?](repeating: nil, count: seeds.count))

        // Setup for test execution
        let coverageCountersClient = Self.fetchCoverageCounters()
        let sourceLocation = config.sourceLocation

        // Resolve the RNG from the dependency once here, then pass it to the
        // generate/mutate functions. Caching it avoids dependency-injection
        // overhead per call (millions of calls) while still sourcing randomness
        // from the injected `\.fastRNG`.
        @Dependency(\.fastRNG) var fastRNG
        var rng = fastRNG

        // Simple fuzz loop - no workers, just iterate
        var iterationCount = 0
        var generatedCount = 0

        // Wrap entire loop in issue capture context to avoid per-iteration TaskLocal overhead.
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

            // Set up the coverage evaluator before the first test execution.
            // pathTrie needs to attach its trie to the context so edges
            // advance the trie during the very first iteration.
            coverageEvaluator.setup?(coverageContext)

            // Check time limit every N iterations to avoid per-iteration Date.init() overhead.
            // With ~10M iterations/sec and default interval of 1000, this means ~10K checks/sec.
            // The interval is configurable via FuzzEngineConfig for tests that need precise control.
            let timeLimitCheckInterval = config.timeLimitCheckInterval
            var iterationsSinceTimeCheck = timeLimitCheckInterval  // Force check on first iteration

            // Establish coverage inheritance for the whole loop so that edges
            // recorded by child tasks (TaskGroup.addTask / Task {}) spawned inside
            // the test body are attributed to this engine's measurement context.
            // Set once outside the per-iteration hot path — the context is hoisted.
            let coverageContextBits = coverageContext.inheritanceHandle
            await CoverageInheritance.$context.withValue(coverageContextBits) {
                CoverageInheritance.captureKeyIfNeeded(contextBits: coverageContextBits)

                while !Task.isCancelled && haltReason == nil {
                    // Check time limit periodically (avoids overhead from per-iteration Date.init)
                    iterationsSinceTimeCheck += 1
                    if iterationsSinceTimeCheck >= timeLimitCheckInterval {
                        iterationsSinceTimeCheck = 0
                        if await haltIfTimeExceeded() {
                            break
                        }
                    }

                    // Get input: from pending queue or generate random.
                    // Schedule bytes (when scheduling) are element 0 of the input
                    // pack, generated/mutated by the prepended schedule mutator like
                    // any other element, and read back via `scheduleBytesExtractor`.
                    let input: (repeat each Input)
                    let fromMutationQueue: Bool
                    let parentID: Int?
                    if !pendingInputs.isEmpty {
                        input = pendingInputs.removeFirstUnchecked()
                        parentID = pendingParents.removeFirstUnchecked()
                        fromMutationQueue = true
                        if seedsRunCount < seeds.count {
                            seedsRunCount += 1
                        } else {
                            mutantsRunCount += 1
                        }
                    } else {
                        // Generate directly - no closure indirection
                        input = (repeat (each mutators).generate(&rng))
                        generatedCount += 1
                        fromMutationQueue = false
                        parentID = nil
                    }
                    let currentScheduleBytes: [UInt8]? = scheduleBytesExtractor(input)

                    // Inputs still queued after taking this one. A plugin can use
                    // `queueCount == 0` to detect that the queue has drained — e.g. to
                    // stop a regression replay before any fresh input is generated.
                    let queueCount = pendingInputs.count

                    // Reset coverage for this iteration
                    coverageCountersClient.resetCoverage(coverageContext)

                    // Run the test, capturing coverage on success and recording failures.
                    var failureRecorded = false
                    do {
                        // Will throw if either the test throws or if it logs an Issue.
                        // When scheduling is being fuzzed, run the test under the
                        // recorded/generated schedule so task interleaving is controlled.
                        // The coverage context is forwarded so edges recorded by the
                        // schedule-controlled tasks are attributed to this measurement.
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
                    } catch is CancellationError {
                        // Allow clean exit on cancellation
                        break
                    } catch {
                        recordFailure(input: input, error: error)
                        failureRecorded = true
                    }

                    // Delegate interestingness to the coverage evaluator. It returns
                    // the run's coverage when the input was interesting (the sparse
                    // snapshot it already took for the decision — no re-snapshot
                    // here), nil otherwise.
                    let iterationCoverage = coverageEvaluator.evaluate(
                        input,
                        currentScheduleBytes,
                        coverageContext,
                        coverageCountersClient,
                        corpus
                    )

                    // Process iteration event before failure event
                    var events = [
                        PluginEvent.sync(
                            .iteration(
                                .init(
                                    input: input,
                                    scheduleBytes: currentScheduleBytes,
                                    fromMutationQueue: fromMutationQueue,
                                    queueCount: queueCount,
                                    newCoverage: iterationCoverage,
                                    parentID: parentID
                                )
                            ))
                    ]

                    if failureRecorded {
                        events.append(
                            .async(
                                .failureFound(
                                    .init(
                                        input: input,
                                        scheduleBytes: currentScheduleBytes,
                                        test: testWithIssueCapture,
                                        sourceLocation: sourceLocation,
                                        // TODO: This should probably throw if we can't gather coverage
                                        sparseCoverage: iterationCoverage
                                            ?? (try? coverageCountersClient
                                                .snapshotCoveredArraysWithContext(coverageContext))
                                            ?? SparseCoverage()
                                    )
                                )
                            )
                        )
                    }

                    await process(events: events)

                    iterationCount += 1
                }
            }
        }

        if config.verbose {
            print(
                "[FUZZ] Fuzz loop finished: iterations=\(iterationCount), generated=\(generatedCount), haltReason=\(String(describing: haltReason))"
            )
        }

        let stats = FuzzStats(
            totalInputs: iterationCount,
            seeds: seedsRunCount,
            mutations: mutantsRunCount,
            generations: generatedCount,
            duration: startTime.distance(to: dateClient.now()),
            stopReason: haltReason ?? .timeLimit,
            failures: failures.count
        )

        if config.verbose {
            print(
                "[FUZZ] FuzzStateMachine.start() finished: totalInputs=\(stats.totalInputs), duration=\(stats.duration), stopReason=\(stats.stopReason)"
            )
        }
        return FuzzStateMachineResult(
            stats: stats,
            corpus: corpus,
            failures: failures,
            campaignStopRequested: haltScope == .campaign
        )
    }

    private func process(events: [PluginEvent<repeat each Input>]) async {
        for event in events {
            switch event {
            case let .sync(event): processSyncPlugins(event, executeAction)
            case let .async(event): await processAsyncPlugins(event, executeAction)
            }
        }
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

    /// Halts the run if the configured time budget has elapsed. The caller gates how
    /// often this runs (every `timeLimitCheckInterval` iterations).
    private func haltIfTimeExceeded() async -> Bool {
        // Yield to allow other tasks to run (enables parallel fuzz runs)
        await Task.yield()
        let elapsed = Duration.seconds(dateClient.now().timeIntervalSince(startTime))
        if elapsed >= config.maxDuration {
            haltReason = .timeLimit
            return true
        }
        return false
    }

    private static func fetchCoverageCounters() -> CoverageCountersClient {
        @Dependency(\.coverageCounters) var coverageCounters
        return coverageCounters
    }

    /// Executes a single plugin action.
    private func executeAction(_ action: FuzzPluginAction<repeat each Input>) {
        switch action {
        case .stop(let stopAction):
            halt(reason: stopAction.reason, scope: stopAction.scope)

        case .recordIssue(let issueAction):
            Issue.record(issueAction.comment, sourceLocation: issueAction.sourceLocation)

        case .queueInputs(let queueAction):
            pendingInputs.append(contentsOf: queueAction.inputs)
            pendingParents.append(contentsOf: [Int?](repeating: nil, count: queueAction.inputs.count))

        case .selectForMutation(let mutationAction):
            // Generate input mutations. When scheduling, element 0 holds the
            // schedule bytes and is mutated by the prepended schedule mutator as
            // part of `generateMutations`, so schedule mutation is unified with
            // input mutation — no separate schedule-byte pass.
            // Each mutant carries the action's originID so iteration events can
            // report the lineage back to the emitting plugin.
            let mutants = generateMutations(mutationAction.input)
            pendingInputs.append(contentsOf: mutants)
            pendingParents.append(contentsOf: [Int?](repeating: mutationAction.originID, count: mutants.count))

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

    private func halt(reason: FuzzStats.StopReason, scope: StopScope = .engine) {
        haltReason = reason
        // A campaign-scoped stop wins; never downgrade once requested.
        if scope == .campaign { haltScope = .campaign }
    }

    private func addToCorpus(
        _ input: (repeat each Input), scheduleBytes: [UInt8]? = nil, sparse: SparseCoverage,
        type: CorpusEntryType, failureInfo: FailureInfo?
    ) {
        corpus.add(input: input, scheduleBytes: scheduleBytes, sparse: sparse, entryType: type, failure: failureInfo)
    }

    /// Generate mutations for an input by mutating one position at a time.
    /// Returns the cartesian product of mutations across all positions.
    private func generateMutations(_ input: (repeat each Input)) -> [(repeat each Input)] {
        let positionsMutated: [(repeat [each Input])] = (0..<inputSize).map { replacementIndex in
            var currentIndex = 0
            return
                (repeat {
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
