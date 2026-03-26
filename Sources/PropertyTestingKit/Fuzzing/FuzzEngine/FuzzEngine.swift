//
//  FuzzEngine.swift
//  PropertyTestingKit
//
//  Coverage-guided fuzzing engine that combines mutation and generation.
//

import Dependencies
import Foundation
import ScheduleControl
import Testing

// MARK: - FuzzEngine

/// A coverage-guided fuzzing engine.
///
/// The engine runs in two modes:
/// 1. **Fuzz mode**: Generate inputs, track coverage, build corpus
/// 2. **Regression mode**: Replay saved corpus, check for crashes
///
/// ## Corpus Modes
///
/// Control behavior with `Config.corpusMode`:
/// - `.auto`: Run regression if corpus exists, otherwise fuzz (default)
/// - `.refuzzReplace`: Always fuzz fresh, replacing existing corpus
/// - `.refuzzExtend`: Load corpus as seeds, continue fuzzing to find more
/// - `.regressionOnly`: Only run regression, fail if no corpus
///
/// Set `FUZZ_CORPUS_MODE` environment variable for suite-level control.
///
/// ## Algorithm
///
/// Fuzzing follows AFL/FuzzChick's approach:
/// 1. Start with boundary values from `Mutator.seeds`
/// 2. Run each input, capture coverage signature
/// 3. If signature is new, add to corpus
/// 4. Select corpus entries for mutation (energy-based)
/// 5. Mutate inputs, repeat
/// 6. Stop when: iteration limit, time limit, or coverage plateau
/// 7. Minimize corpus, save to disk
///
final class FuzzEngine<each Input: Codable & Sendable>: @unchecked Sendable {
    @Dependency(\.dateClient) private var dateClient
    @Dependency(\.corpusPersistence) private var corpusPersistenceClient
    @Dependency(\.coverageCounters) private var coverageCounters
    @Dependency(\.corpusRegistry) private var corpusRegistry

    // Type alias for the combined input tuple
    typealias InputTuple = (repeat each Input)

    /// Synchronous plugin processor for iteration events (hot path).
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

    // MARK: - Properties
    private let config: FuzzEngineConfig
    private let corpusDirectory: URL?
    private let mutators: (repeat Mutator<each Input>)
    private let inputSize: Int
    private let seeds: [(repeat each Input)]

    /// Initialize with mutators.
    ///
    /// - Parameters:
    ///   - mutators: A tuple of mutators, one for each input type.
    ///   - config: Fuzzing configuration.
    ///   - corpusDirectory: Where to save/load the corpus.
    init(
        mutators: (repeat Mutator<each Input>),
        config: FuzzEngineConfig = FuzzEngineConfig(),
        corpusDirectory: URL? = nil
    ) {
        let inputSize = Self.inputCount(for: repeat (each Input).self)
        self.config = config
        self.corpusDirectory = corpusDirectory
        self.mutators = mutators
        self.inputSize = inputSize
        self.seeds = Self.extractSeeds(mutators: mutators, inputSize: inputSize)
    }

    /// Extract seeds from mutators using cartesian product expansion.
    private static func extractSeeds(
        mutators: (repeat Mutator<each Input>),
        inputSize: Int
    ) -> [(repeat each Input)] {
        let positionsExpanded: [(repeat [each Input])] = (0..<inputSize).map { expandIndex in
            var currentIndex = 0
            return (repeat {
                defer { currentIndex += 1 }
                let seeds = (each mutators).seeds
                if currentIndex == expandIndex {
                    return seeds
                } else {
                    return [seeds[0]]
                }
            }())
        }
        return positionsExpanded.flatMap(cartesianProduct)
    }

    // MARK: - Helpers

    /// Count the number of elements in a parameter pack.
    private static func inputCount(for input: repeat (each Input).Type) -> Int {
        var count = 0
        (repeat { _ = each input; count += 1 }())
        return count
    }

    // MARK: - Fuzzing

    /// Run the fuzzing engine.
    ///
    /// - Parameters:
    ///   - additionalSeeds: Extra seed values to include alongside `Input.fuzz` defaults.
    ///     Use this to provide domain-specific inputs that target your code's edge cases.
    ///   - processSyncPlugins: Sync plugin processor for iteration events (hot path).
    ///   - processAsyncPlugins: Async plugin processor for rare events (cold path).
    ///   - test: The test closure to fuzz.
    /// - Returns: The fuzz result with corpus and any failures.
    func run(
        additionalSeeds: [InputTuple] = [],
        processSyncPlugins: @escaping SyncPluginProcessorFn,
        processAsyncPlugins: @escaping AsyncPluginProcessorFn,
        test: @escaping @Sendable (InputTuple) async throws -> Void
    ) async -> FuzzResult<repeat each Input> {
        return await runWithMode(additionalSeeds: additionalSeeds, processSyncPlugins: processSyncPlugins, processAsyncPlugins: processAsyncPlugins, test: test)
    }

    /// Internal dispatch based on corpus mode.
    private func runWithMode(
        additionalSeeds: [InputTuple],
        processSyncPlugins: @escaping SyncPluginProcessorFn,
        processAsyncPlugins: @escaping AsyncPluginProcessorFn,
        test: @escaping @Sendable (InputTuple) async throws -> Void
    ) async -> FuzzResult<repeat each Input> {
        let corpusExists = corpusDirectory.map { corpusPersistenceClient.exists($0) } ?? false

        // Handle refuzzReplace: delete corpus and fuzz fresh
        if config.corpusMode == .refuzzReplace {
            if corpusExists, let directory = corpusDirectory {
                if config.verbose {
                    print("[Fuzz] Mode: refuzzReplace - deleting existing corpus")
                }
                try? corpusPersistenceClient.delete(directory)
            }
            return await runFuzzing(additionalSeeds: additionalSeeds, processSyncPlugins: processSyncPlugins, processAsyncPlugins: processAsyncPlugins, test: test)
        }

        // Handle refuzzExtend: load corpus as seeds and continue fuzzing
        if config.corpusMode == .refuzzExtend {
            var allSeeds = additionalSeeds
            if corpusExists, let directory = corpusDirectory {
                do {
                    let savedSnapshot: CorpusSnapshot<repeat each Input> = try corpusPersistenceClient.loadSnapshot(from: directory, scheduleFuzzing: config.scheduleFuzzing)
                    if config.verbose {
                        print("[Fuzz] Mode: refuzzExtend - loaded \(savedSnapshot.count) existing corpus entries as seeds")
                    }
                    allSeeds.append(contentsOf: savedSnapshot.entries.map(\.input))
                } catch {
                    if config.verbose {
                        print("[Fuzz] Failed to load corpus for extension: \(error)")
                    }
                }
            }
            return await runFuzzing(additionalSeeds: allSeeds, processSyncPlugins: processSyncPlugins, processAsyncPlugins: processAsyncPlugins, test: test)
        }

        // Handle regressionOnly: only run regression, return empty if no corpus
        if config.corpusMode == .regressionOnly {
            guard corpusExists, let directory = corpusDirectory else {
                if config.verbose {
                    print("[Fuzz] Mode: regressionOnly - no corpus found, nothing to regress")
                }
                return .empty
            }
            do {
                let savedSnapshot: CorpusSnapshot<repeat each Input> = try corpusPersistenceClient.loadSnapshot(from: directory, scheduleFuzzing: config.scheduleFuzzing)
                return await runRegression(snapshot: savedSnapshot, processSyncPlugins: processSyncPlugins, processAsyncPlugins: processAsyncPlugins, test: test)
            } catch {
                if config.verbose {
                    print("[Fuzz] Mode: regressionOnly - failed to load corpus: \(error)")
                }
                return .empty
            }
        }

        // Default (auto): regression if corpus exists, otherwise fuzz
        if corpusExists, let directory = corpusDirectory {
            do {
                let savedSnapshot: CorpusSnapshot<repeat each Input> = try corpusPersistenceClient.loadSnapshot(from: directory, scheduleFuzzing: config.scheduleFuzzing)
                return await runRegression(snapshot: savedSnapshot, processSyncPlugins: processSyncPlugins, processAsyncPlugins: processAsyncPlugins, test: test)
            } catch {
                if config.verbose {
                    print("[Fuzz] Failed to load corpus: \(error), starting fresh")
                }
            }
        }

        return await runFuzzing(additionalSeeds: additionalSeeds, processSyncPlugins: processSyncPlugins, processAsyncPlugins: processAsyncPlugins, test: test)
    }

    // MARK: - Fuzz Mode

    private func runFuzzing(
        additionalSeeds: [InputTuple] = [],
        processSyncPlugins: @escaping SyncPluginProcessorFn,
        processAsyncPlugins: @escaping AsyncPluginProcessorFn,
        test: @escaping @Sendable (InputTuple) async throws -> Void
    ) async -> FuzzResult<repeat each Input> {
        // Filter compiler-generated edges before any measurement.
        // This is a one-time scan (~2s for large binaries), so we do it before
        // capturing startTime so it doesn't eat into the fuzz duration budget.
        SanCovCounters.applyEdgeFilter()
        if config.verbose {
            let filtered = SanCovCounters.filteredEdgeCount
            if filtered > 0 {
                print("[Fuzz] Filtered \(filtered) compiler-generated edges")
            }
        }

        let startTime = dateClient.now()

        // Install custom edge hook if configured
        SanCovCounters.setEdgeHook(config.edgeHook)

        let allSeeds = additionalSeeds + seeds

        // Early exit if no seeds and no way to generate inputs
        if allSeeds.isEmpty {
            if config.verbose {
                print("[Fuzz] No seeds and no mutations possible - exiting early")
            }
            return .empty
        }

        let corpus: Corpus<repeat each Input> = corpusRegistry.getCorpus()
        let coverageStrategy: CoverageStrategyFn<repeat each Input> = makeCoverageStrategy(config.coverageStrategy)

        let stateMachine = FuzzStateMachine<repeat each Input>(
            seeds: allSeeds,
            mutators: mutators,
            inputSize: inputSize,
            corpus: corpus,
            coverageStrategy: coverageStrategy,
            processSyncPlugins: processSyncPlugins,
            processAsyncPlugins: processAsyncPlugins,
            config: config,
            startTime: startTime,
            test: test
        )

        let stateMachineResult = try! await stateMachine.start()

        // Extract copyable fields
        let stats = stateMachineResult.stats
        let failures = stateMachineResult.failures
        var resultCorpus = stateMachineResult.corpus

        // Phase 3: Minimize corpus
        let corpusCountBeforeMinimize = resultCorpus.count
        if config.minimizeCorpus && corpusCountBeforeMinimize > 1 {
            let minimizedSnapshot = resultCorpus.minimized()
            resultCorpus = Corpus(from: minimizedSnapshot)
            if config.verbose {
                let finalCount = resultCorpus.count
                print("[Fuzz] Minimized corpus: \(corpusCountBeforeMinimize) -> \(finalCount)")
            }
        }

        // Phase 4: Save corpus
        if let directory = corpusDirectory {
            do {
                let snapshotToSave = resultCorpus.snapshot()
                try corpusPersistenceClient.save(snapshotToSave, to: directory, scheduleFuzzing: config.scheduleFuzzing)
                if config.verbose {
                    print("[Fuzz] Saved corpus to \(directory.path)")
                }
            } catch {
                if config.verbose {
                    print("[Fuzz] Failed to save corpus: \(error)")
                }
            }
        }

        let finalSnapshot = resultCorpus.snapshot()

        // Send .end event to plugins (for coverage gap analysis, etc.)
        let endContext = AsyncPluginEvent<repeat each Input>.EndContext(
            totalCoveredIndices: finalSnapshot.coveredIndices,
            projectPath: config.projectPath,
            sourceLocation: config.sourceLocation
        )
        await processAsyncPlugins(nil, .end(endContext)) { action in
            self.executeEndAction(action)
        }

        return FuzzResult(
            corpus: finalSnapshot,
            failures: failures,
            stats: stats,
            wasRegression: false
        )
    }

    /// Execute plugin actions from .end event.
    private func executeEndAction(_ action: FuzzPluginAction<repeat each Input>) {
        switch action {
        case .recordIssue(let issueAction):
            Issue.record(issueAction.comment, sourceLocation: issueAction.sourceLocation)
        default:
            // Other actions not applicable at end time
            break
        }
    }

    // MARK: - Regression Mode

    private func runRegression(
        snapshot: CorpusSnapshot<repeat each Input>,
        processSyncPlugins: @escaping SyncPluginProcessorFn,
        processAsyncPlugins: @escaping AsyncPluginProcessorFn,
        test: @escaping @Sendable (InputTuple) async throws -> Void
    ) async -> FuzzResult<repeat each Input> {
        // Filter compiler-generated edges before any measurement
        SanCovCounters.applyEdgeFilter()

        let startTime = dateClient.now()
        var failures: [(input: InputTuple, error: Error, timeElapsed: TimeInterval)] = []

        if config.verbose {
            let filtered = SanCovCounters.filteredEdgeCount
            print("[Regression] Filtered \(filtered) compiler-generated edges out of \(SanCovCounters.totalEdgeCount)")
            print("[Regression] Running \(snapshot.count) saved inputs...")
        }

        // Install custom edge hook if configured
        SanCovCounters.setEdgeHook(config.edgeHook)

        // Measure live coverage during regression for accurate .end event
        let context = coverageCounters.beginMeasurement()
        defer { coverageCounters.endMeasurement(context) }
        var liveCoveredIndices = Set<UInt32>()

        for (index, entry) in snapshot.entries.enumerated() {
            if config.verbose {
                print("[Regression] Replaying input \(index + 1)/\(snapshot.count)")
            }

            coverageCounters.resetCoverage(context)

            do {
                if let bytes = entry.scheduleBytes {
                    try await ScheduleController.run(scheduleBytes: bytes) {
                        try await test(entry.input)
                    }
                } else {
                    try await test(entry.input)
                }
            } catch {
                failures.append((entry.input, error, startTime.distance(to: dateClient.now())))
            }

            // Accumulate live coverage
            if let sparse = try? coverageCounters.snapshotCoveredArraysWithContext(context) {
                for idx in sparse.indices {
                    liveCoveredIndices.insert(idx)
                }
            }
        }

        let duration = dateClient.now().timeIntervalSince(startTime)
        let stats = FuzzStats(
            totalInputs: snapshot.count,
            mutations: 0,
            generations: 0,
            duration: duration,
            stopReason: .regression,
        )

        if config.verbose {
            print("[Regression] Completed: \(snapshot.count) inputs, \(failures.count) failures, \(String(format: "%.2f", duration))s")
        }

        // Send .end event with live coverage (not stale persisted values)
        let endContext = AsyncPluginEvent<repeat each Input>.EndContext(
            totalCoveredIndices: liveCoveredIndices,
            projectPath: config.projectPath,
            sourceLocation: config.sourceLocation
        )
        await processAsyncPlugins(nil, .end(endContext)) { action in
            self.executeEndAction(action)
        }

        return FuzzResult(
            corpus: snapshot,
            failures: failures,
            stats: stats,
            wasRegression: true
        )
    }
}

func runWithTimeout(
    timeout: Duration,
    _ task: @Sendable @escaping () async throws -> Void
) async rethrows -> Bool {
    @Dependency(\.continuousClockClient) var clock
    return try await withThrowingTaskGroup(of: Bool.self) { timeoutGroup in
        timeoutGroup.addTask {
            try await task()
            return false
        }
        timeoutGroup.addTask { [clock] in
            try await clock.sleep(for: timeout)
            return true
        }
        let didHang = try await timeoutGroup.next()
        timeoutGroup.cancelAll()
        return didHang ?? false
    }
}
