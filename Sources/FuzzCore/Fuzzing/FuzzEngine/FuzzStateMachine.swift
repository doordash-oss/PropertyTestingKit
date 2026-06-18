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

    /// Instrumentation providers injected by the batteries layer. The core
    /// engine names no signal: it installs a probe for each key the scheduler
    /// requires by matching provider keys, never by referencing coverage.
    private let providers: [any InstrumentationProvider]

    /// This engine's scheduler: consulted for what to run when the residual
    /// queue is empty (it produces the input itself), and told about every
    /// iteration's outcome through the per-execution `RawExecutionContext`. It
    /// owns its own working set — the engine holds no pool.
    private let scheduler: AnyScheduler<repeat each Input>
    /// Instrumentation probes feeding the scheduler. Built in `start()` once the
    /// measurement context exists, then assembled into a `RawExecutionContext`
    /// each iteration.
    private var probes: [any InstrumentationProbe] = []

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
        providers: [any InstrumentationProvider],
        scheduler: AnyScheduler<repeat each Input>,
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
        self.providers = providers
        self.scheduler = scheduler
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
        /// Run-spanning instrumentation summary, assembled from the installed
        /// probes at campaign end and surfaced to the `.end` event. The engine
        /// names no signal: a probe contributes its own aggregate (e.g. the
        /// coverage probe's union of covered edges) via
        /// `contributeCampaignSummary`. Empty when no probe contributes one.
        let campaignSummary: RawExecutionContext
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
        pendingParents.append(nil, repeated: seeds.count)  // seeds have no lineage parent

        // Setup for test execution
        let sourceLocation = config.sourceLocation

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

            // Install a probe for each key some active scheduler requires —
            // matching the injected providers by key, so the engine never names
            // a signal here. Each probe owns its native measurement lifecycle
            // (coverage allocates its SanCov context in `setUp`, frees it in
            // `tearDown`).
            let requiredKeys = Set(scheduler.requiredProbes.map { ObjectIdentifier($0) })
            probes = providers
                .filter { requiredKeys.contains(ObjectIdentifier($0.key)) }
                .map { $0.makeProbe() }

            // Set up probes before the first test execution (pathTrie attaches its
            // trie so edges advance during iteration 1); tear down after the loop.
            for probe in probes { probe.setUp() }
            defer { for probe in probes { probe.tearDown() } }

            // Check time limit every N iterations to avoid per-iteration Date.init() overhead.
            // With ~10M iterations/sec and default interval of 1000, this means ~10K checks/sec.
            // The interval is configurable via FuzzEngineConfig for tests that need precise control.
            let timeLimitCheckInterval = config.timeLimitCheckInterval
            var iterationsSinceTimeCheck = timeLimitCheckInterval  // Force check on first iteration

            // Run the loop inside every installed probe's campaign scope, nested
            // in install order. The engine names no signal: coverage uses its
            // scope to install the inheritance task-local for the loop's lifetime
            // (so child-task edges are attributed to this engine); other probes
            // default to a transparent scope.
            await withProbeCampaignScopes(probes[...]) {

                while !Task.isCancelled && haltReason == nil {
                    // Check time limit periodically (avoids overhead from per-iteration Date.init)
                    iterationsSinceTimeCheck += 1
                    if iterationsSinceTimeCheck >= timeLimitCheckInterval {
                        iterationsSinceTimeCheck = 0
                        if await haltIfTimeExceeded() {
                            break
                        }
                    }

                    // Get input: the residual queue (seeds, queueInputs, bus
                    // bursts) has priority; otherwise the scheduler directs —
                    // mutate a pool entry or generate fresh.
                    // Schedule bytes (when scheduling) are element 0 of the input
                    // pack, generated/mutated by the prepended schedule mutator like
                    // any other element, and read back via `scheduleBytesExtractor`.
                    let input: (repeat each Input)
                    let fromMutationQueue: Bool
                    let parentID: Int?
                    let poolParentID: Int?
                    let source: SchedulerSource
                    if !pendingInputs.isEmpty {
                        assert(
                            pendingParents.count == pendingInputs.count,
                            "lineage buffers desynced: \(pendingParents.count) parents vs \(pendingInputs.count) inputs"
                        )
                        input = pendingInputs.removeFirstUnchecked()
                        parentID = pendingParents.removeFirstUnchecked()
                        poolParentID = nil
                        fromMutationQueue = true
                        source = .external
                        if seedsRunCount < seeds.count {
                            seedsRunCount += 1
                        } else {
                            mutantsRunCount += 1
                        }
                    } else {
                        // The scheduler owns production: it generates a fresh
                        // input or mutates one of its own retained entries. The
                        // engine doesn't know or care which — `poolParentID` is
                        // an opaque attribution tag the scheduler chose (`nil`
                        // for a generated input), round-tripped to plugins.
                        let scheduled = scheduler.next()
                        input = scheduled.input
                        poolParentID = scheduled.poolParentID
                        parentID = nil
                        source = .scheduled
                        if scheduled.poolParentID == nil {
                            generatedCount += 1
                            fromMutationQueue = false
                        } else {
                            mutantsRunCount += 1
                            fromMutationQueue = true
                        }
                    }
                    let currentScheduleBytes: [UInt8]? = scheduleBytesExtractor(input)

                    // Inputs still queued after taking this one. A plugin can use
                    // `queueCount == 0` to detect that the queue has drained — e.g. to
                    // stop a regression replay before any fresh input is generated.
                    let queueCount = pendingInputs.count

                    // Reset probes for this iteration (coverage clears its map).
                    for probe in probes { probe.reset() }

                    // Run the test, capturing coverage on success and recording failures.
                    var failureRecorded = false
                    do {
                        // Will throw if either the test throws or if it logs an Issue.
                        // When scheduling is being fuzzed, run the test under the
                        // recorded/generated schedule so task interleaving is controlled.
                        // Coverage attribution for schedule-controlled child tasks
                        // rides the inheritance task-local installed by the coverage
                        // probe's campaign scope, so the engine forwards no
                        // coverage-specific context here.
                        if let bytes = currentScheduleBytes {
                            try await ScheduleController.run(
                                scheduleBytes: bytes
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

                    // Assemble the per-execution context from the installed
                    // probes; the scheduler reads whatever signals it needs out
                    // of it. The engine names no signal when handing this over.
                    var execContext = RawExecutionContext()
                    for probe in probes { probe.contribute(to: &execContext) }

                    // Retention is the scheduler's call. `observe` reads whatever
                    // signals it needs out of the context, folds them into its
                    // own state (and its own working set, if any), and returns
                    // the signature to persist when the input should be retained
                    // in the corpus — or nil to retain nothing. The engine names
                    // no signal and owns no pool: it only persists the corpus
                    // entry (the result/dedup/cross-engine-merge store).
                    if let signature = scheduler.observe(input, execContext, source) {
                        corpus.mergeCoverageAndAdd(
                            input: input,
                            scheduleBytes: currentScheduleBytes,
                            sparse: signature
                        )
                    }

                    // Process iteration event before failure event
                    var events = [
                        PluginEvent.sync(
                            .iteration(
                                .init(
                                    input: input,
                                    scheduleBytes: currentScheduleBytes,
                                    fromMutationQueue: fromMutationQueue,
                                    queueCount: queueCount,
                                    executionContext: execContext,
                                    parentID: parentID,
                                    poolParentID: poolParentID
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
                                        // The failing run's per-execution signals;
                                        // a coverage-aware plugin reads its verdict
                                        // out of this to tag the submitted entry.
                                        executionContext: execContext
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
        // Assemble the run-spanning summary from the installed probes (e.g. the
        // coverage probe contributes its union of covered edges). The engine
        // names no signal — each probe contributes its own aggregate by key.
        var campaignSummary = RawExecutionContext()
        for probe in probes { probe.contributeCampaignSummary(to: &campaignSummary) }

        return FuzzStateMachineResult(
            stats: stats,
            corpus: corpus,
            failures: failures,
            campaignSummary: campaignSummary,
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

    /// Run `body` nested inside every probe's `withCampaignScope`, in array
    /// order. The engine names no signal — it just composes whatever scopes the
    /// installed probes provide around the whole loop.
    private func withProbeCampaignScopes(
        _ probes: ArraySlice<any InstrumentationProbe>,
        _ body: () async -> Void
    ) async {
        guard let first = probes.first else {
            await body()
            return
        }
        await first.withCampaignScope {
            await self.withProbeCampaignScopes(probes.dropFirst(), body)
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

    /// Executes a single plugin action.
    private func executeAction(_ action: FuzzPluginAction<repeat each Input>) {
        switch action {
        case .stop(let stopAction):
            halt(reason: stopAction.reason, scope: stopAction.scope)

        case .recordIssue(let issueAction):
            Issue.record(issueAction.comment, sourceLocation: issueAction.sourceLocation)

        case .queueInputs(let queueAction):
            // Directly-queued inputs are lineage roots, not mutants of any
            // entry, so they carry no parent (reported as `parentID == nil`).
            enqueuePending(queueAction.inputs, parent: nil)

        case .selectForMutation(let mutationAction):
            // Queue a fixed burst of single-step mutants. When scheduling,
            // element 0 holds the schedule bytes and is mutated by the
            // prepended schedule mutator like any other position, so schedule
            // mutation is unified with input mutation.
            // Each mutant carries the action's originID so iteration events can
            // report the lineage back to the emitting plugin.
            // `FastRNG` is a stateless shim over the thread-local generator, so
            // a fresh instance draws from the same stream; the `inout` threading
            // is for a uniform mutator signature, not seeding.
            var mutationRNG = FastRNG()
            let mutants = (0..<mutationBurstLength).map { _ in
                mutateOneRandomPosition(
                    mutationAction.input,
                    inputSize: inputSize,
                    rng: &mutationRNG,
                    mutators: repeat each mutators
                )
            }
            enqueuePending(mutants, parent: mutationAction.originID)

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

    /// Enqueue inputs with their shared lineage parent, keeping
    /// `pendingInputs` and `pendingParents` in lockstep. This is the single
    /// place that maintains that invariant; every other site dequeues them
    /// together in `start()`.
    private func enqueuePending(_ inputs: [(repeat each Input)], parent: Int?) {
        pendingInputs.append(contentsOf: inputs)
        pendingParents.append(parent, repeated: inputs.count)
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

}

/// How many single-step mutants a `.selectForMutation` action queues.
///
/// Interim constant: effort per selection becomes scheduler state (focus +
/// counter) when the pool scheduler lands; until then this preserves a
/// burst-on-accept shape comparable to the old exhaustive-neighborhood burst.
let mutationBurstLength = 16
