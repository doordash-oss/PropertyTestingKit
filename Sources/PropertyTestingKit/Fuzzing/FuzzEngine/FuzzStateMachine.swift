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

    /// The coverage evaluator that determines interestingness. Wrapped in a
    /// `CoverageProbe` and driven through the generic instrumentation seam.
    private let coverageEvaluator: CoverageEvaluator

    /// This engine's scheduler: consulted for what to run when the residual
    /// queue is empty, told about every iteration's outcome through the
    /// per-execution `RawExecutionContext`.
    private let scheduler: any SchedulerCore
    /// Instrumentation probes feeding the scheduler. Built in `start()` once the
    /// measurement context exists, then assembled into a `RawExecutionContext`
    /// each iteration.
    private var probes: [any InstrumentationProbe] = []
    /// The coverage probe, when the scheduler required it. Held so the engine
    /// can read its accumulated covered-edge set at teardown for the `.end`
    /// (coverage-gap) event — the one coverage-specific read left, and it sits
    /// outside the hot loop.
    private var installedCoverageProbe: CoverageProbe?
    /// Typed inputs for pool entries, index == pool entry ID. Append-only —
    /// eviction is the scheduler's concern (live set), not storage's.
    private var poolEntries: [(repeat each Input)] = []

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
        coverageEvaluator: CoverageEvaluator,
        scheduler: any SchedulerCore,
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
        /// Union of edge indices across every interesting run, surfaced from the
        /// coverage probe so the engine can feed the coverage-gap (`.end`) event
        /// without the corpus owning a coverage bitmap. Empty when no coverage
        /// probe was installed.
        let coveredIndices: Set<UInt32>
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

            // Build the default instrumentation providers, then install a probe
            // for each key some active scheduler requires — matching by key, so
            // the engine never names a signal here. Coverage is the only built-in
            // provider today; a userspace module supplies its own. Each probe
            // owns its native measurement lifecycle (coverage allocates its
            // SanCov context in `setUp`, frees it in `tearDown`).
            let providers: [any InstrumentationProvider] = [
                CoverageProvider(evaluator: coverageEvaluator, client: coverageCountersClient)
            ]
            let requiredKeys = Set(type(of: scheduler).requiredProbes.map { ObjectIdentifier($0) })
            probes = providers
                .filter { requiredKeys.contains(ObjectIdentifier($0.key)) }
                .map { $0.makeProbe() }
            // The coverage probe, if installed, owns the aggregate covered-edge
            // set the engine reads at teardown for the `.end` event.
            installedCoverageProbe = probes.compactMap { $0 as? CoverageProbe }.first

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
                    if !pendingInputs.isEmpty {
                        assert(
                            pendingParents.count == pendingInputs.count,
                            "lineage buffers desynced: \(pendingParents.count) parents vs \(pendingInputs.count) inputs"
                        )
                        input = pendingInputs.removeFirstUnchecked()
                        parentID = pendingParents.removeFirstUnchecked()
                        poolParentID = nil
                        fromMutationQueue = true
                        if seedsRunCount < seeds.count {
                            seedsRunCount += 1
                        } else {
                            mutantsRunCount += 1
                        }
                    } else {
                        switch scheduler.next() {
                        case .generate:
                            // Generate directly - no closure indirection
                            input = (repeat (each mutators).generate(&rng))
                            generatedCount += 1
                            fromMutationQueue = false
                            parentID = nil
                            poolParentID = nil
                        case .mutate(let id):
                            input = generateMutation(poolEntries[id])
                            mutantsRunCount += 1
                            fromMutationQueue = true
                            parentID = nil
                            poolParentID = id
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

                    // The coverage view is still read here, but only as data:
                    // the plugin iteration/failure events report it, and an
                    // admitted entry is tagged with it. The retention *decision*
                    // is no longer the engine's — see below.
                    let iterationCoverage = execContext[CoverageProbeKey.self]?.coverage

                    // Retention is the scheduler's call. `observe` reads whatever
                    // signals it needs out of the context and, on admission,
                    // hands back the new entry's ID. The engine names no signal:
                    // an admitted input joins both the mutation pool (typed input
                    // stored at that ID — IDs are sequential, so they stay
                    // aligned) and the result corpus.
                    let poolSource: SchedulerSource =
                        poolParentID.map { .pool(parent: $0) }
                        ?? (fromMutationQueue ? .queue : .generated)
                    if scheduler.observe(execContext, source: poolSource) != nil {
                        poolEntries.append(input)
                        corpus.mergeCoverageAndAdd(
                            input: input,
                            scheduleBytes: currentScheduleBytes,
                            sparse: iterationCoverage ?? SparseCoverage()
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
                                    newCoverage: iterationCoverage,
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
                                        // The failing run's coverage as judged by
                                        // the probe this iteration; empty when the
                                        // run was not interesting. (The engine no
                                        // longer owns a measurement context to take
                                        // a fresh snapshot from.)
                                        sparseCoverage: iterationCoverage ?? SparseCoverage()
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
            coveredIndices: installedCoverageProbe?.coveredIndices ?? [],
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
            let mutants = (0..<mutationBurstLength).map { _ in
                generateMutation(mutationAction.input)
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

    /// Generate ONE mutant: a single mutation step at one randomly chosen
    /// position of the input pack.
    private func generateMutation(_ input: (repeat each Input)) -> (repeat each Input) {
        // A 0-arity pack has no position to mutate; return it unchanged rather
        // than trapping on `Int.random(in: 0..<0)`.
        guard inputSize > 0 else { return input }
        // `FastRNG` is a stateless shim over the thread-local generator, so a
        // fresh instance draws from the same stream as the engine's own `rng`;
        // the `inout` threading is for a uniform mutator signature, not seeding.
        var rng = FastRNG()
        let position = inputSize == 1 ? 0 : Int.random(in: 0..<inputSize, using: &rng)
        return mutateOnePosition(input, position: position, rng: &rng, mutators: repeat each mutators)
    }
}

/// How many single-step mutants a `.selectForMutation` action queues.
///
/// Interim constant: effort per selection becomes scheduler state (focus +
/// counter) when the pool scheduler lands; until then this preserves a
/// burst-on-accept shape comparable to the old exhaustive-neighborhood burst.
let mutationBurstLength = 16

/// Mutate exactly `position` of the input pack with one mutator call, holding
/// every other position fixed.
func mutateOnePosition<each Input>(
    _ input: (repeat each Input),
    position: Int,
    rng: inout FastRNG,
    mutators: repeat Mutator<each Input>
) -> (repeat each Input) {
    var currentIndex = 0
    return (repeat {
        defer { currentIndex += 1 }
        if currentIndex == position {
            return (each mutators).mutate(each input, &rng)
        } else {
            return (each input)
        }
    }())
}
