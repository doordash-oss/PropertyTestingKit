//
//  FuzzEngine.swift
//  PropertyTestingKit
//
//  Coverage-guided fuzzing engine that combines mutation and generation.
//

import Dependencies
import DequeModule
import Foundation
import Testing

// MARK: - FuzzEngine

/// A coverage-guided fuzzing engine.
///
/// The engine runs in two modes:
/// 1. **Fuzz mode**: Generate inputs, track coverage, build corpus
/// 2. **Regression mode**: Replay saved corpus, verify coverage unchanged
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
public actor FuzzEngine<each Input: Codable & Sendable> {
    /// Type-erased mutator functions for each input component.
    public typealias MutatorSeeds = @Sendable () -> [(repeat each Input)]
    public typealias MutatorMutate = @Sendable ((repeat each Input)) -> [(repeat each Input)]
    public typealias MutatorGenerate = @Sendable () -> (repeat each Input)

    @Dependency(\.dateClient) private var dateClient
    @Dependency(\.random) private var random
    @Dependency(\.corpusPersistence) private var corpusPersistenceClient
    @Dependency(\.coverageCounters) private var coverageCounters
    @Dependency(\.corpusRegistry) private var corpusRegistry

    // MARK: - Random Helpers (use injected RNG for determinism)
    private let config: Config
    private let corpusDirectory: URL?
    private let mutatorSeeds: MutatorSeeds
    private let mutatorMutate: MutatorMutate
    private let mutatorGenerate: MutatorGenerate

    /// Initialize with mutators.
    ///
    /// - Parameters:
    ///   - mutators: A tuple of mutators, one for each input type.
    ///   - config: Fuzzing configuration.
    ///   - corpusDirectory: Where to save/load the corpus.
    public init<each M: Mutator>(
        mutators: (repeat each M),
        config: Config = Config(),
        corpusDirectory: URL? = nil
    ) where (repeat (each M).Value) == (repeat each Input) {
        self.config = config
        self.corpusDirectory = corpusDirectory

        // Eagerly extract seeds from mutators
        let eagerlyCapturedSeeds = Self.extractMutatorSeeds(mutators: mutators)

        self.mutatorSeeds = {
            eagerlyCapturedSeeds
        }

        // Capture mutators directly in the closure - no type erasure needed
        self.mutatorMutate = { input in
            Self.mutateWithMutators(input: input, mutators: mutators)
        }

        // Capture generate functionality from mutators
        self.mutatorGenerate = {
            Self.generateWithMutators(mutators: mutators)
        }
    }

    // MARK: - Mutator Helpers

    /// Extract seeds from a tuple of mutators and compute cartesian product.
    private static func extractMutatorSeeds<each M: Mutator>(
        mutators: (repeat each M)
    ) -> [(repeat each Input)] where (repeat (each M).Value) == (repeat each Input) {
        cartesianProduct(repeat (each mutators).seeds)
    }

    /// Count the number of elements in a parameter pack.
    private static func inputCount(for input: repeat each Input) -> Int {
        var count = 0
        (repeat { _ = each input; count += 1 }())
        return count
    }

    /// Generate a random input using the provided mutators.
    /// Uses parameter pack expansion to call generate on each mutator.
    private static func generateWithMutators<each M: Mutator>(
        mutators: (repeat each M)
    ) -> (repeat each Input) where (repeat (each M).Value) == (repeat each Input) {
        (repeat (each mutators).generate())
    }

    /// Mutate an input using the provided mutators.
    /// Uses parameter pack expansion to avoid type erasure.
    private static func mutateWithMutators<each M: Mutator>(
        input: (repeat each Input),
        mutators: (repeat each M)
    ) -> [(repeat each Input)] where (repeat (each M).Value) == (repeat each Input) {
        let count = inputCount(for: repeat each input)

        // For each position, create a tuple of arrays where:
        // - The mutated position contains all mutations from the mutator
        // - Other positions contain just the original value wrapped in an array
        let positionsMutated: [(repeat [each Input])] = (0..<count).map { replacementIndex in
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

        // Use cartesianProduct to expand each position's arrays into full tuples
        return positionsMutated.flatMap(cartesianProduct)
    }

    // MARK: - Fuzzing

    /// Run the fuzzing engine.
    ///
    /// - Parameters:
    ///   - additionalSeeds: Extra seed values to include alongside `Input.fuzz` defaults.
    ///     Use this to provide domain-specific inputs that target your code's edge cases.
    ///   - test: The test closure to fuzz.
    /// - Returns: The fuzz result with corpus and any failures.
    public func run(
        additionalSeeds: [(repeat each Input)] = [],
        test: @escaping @Sendable ((repeat each Input)) async throws -> Void
    ) async -> FuzzResult<repeat each Input> {
        // Start pre-warming the source location cache if gap analysis plugin is present.
        // This runs dladdr calls in the background so they complete by the time
        // gap detection needs them at the end of the fuzz run.
        if config.plugins.contains(where: { $0 is EventBasedCoverageGapPlugin }) {
            await SanCovCounters.startPreWarmingSourceLocations()
        }

        // No lock needed - SanitizerCoverage uses task-keyed maps that provide
        // true per-task isolation, even when tasks share threads.
        return await runWithMode(additionalSeeds: additionalSeeds, test: test)
    }

    /// Internal dispatch based on corpus mode.
    private func runWithMode(
        additionalSeeds: [(repeat each Input)],
        test: @escaping @Sendable ((repeat each Input)) async throws -> Void
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
            return await runFuzzing(additionalSeeds: additionalSeeds, test: test)
        }

        // Handle refuzzExtend: load corpus as seeds and continue fuzzing
        if config.corpusMode == .refuzzExtend {
            var allSeeds = additionalSeeds
            if corpusExists, let directory = corpusDirectory {
                do {
                    let savedSnapshot: CorpusSnapshot<repeat each Input> = try corpusPersistenceClient.loadSnapshot(from: directory)
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
            return await runFuzzing(additionalSeeds: allSeeds, test: test)
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
                let savedSnapshot: CorpusSnapshot<repeat each Input> = try corpusPersistenceClient.loadSnapshot(from: directory)
                return await runRegression(snapshot: savedSnapshot, test: test)
            } catch {
                if config.verbose {
                    print("[Fuzz] Mode: regressionOnly - failed to load corpus: \(error)")
                }
                return .empty
            }
        }

        // Default (auto): regression if corpus exists
        if corpusExists, let directory = corpusDirectory {
            do {
                let savedSnapshot: CorpusSnapshot<repeat each Input> = try corpusPersistenceClient.loadSnapshot(from: directory)
                if await CorpusSchema.isCompatible(savedSnapshot.schemaVersion) {
                    return await runRegression(snapshot: savedSnapshot, test: test)
                } else {
                    if config.verbose {
                        print("[Fuzz] Schema changed, re-fuzzing...")
                    }
                }
            } catch {
                if config.verbose {
                    print("[Fuzz] Failed to load corpus: \(error), starting fresh")
                }
            }
        }

        return await runFuzzing(additionalSeeds: additionalSeeds, test: test)
    }

    // MARK: - Fuzz Mode

    private func runFuzzing(
        additionalSeeds: [(repeat each Input)] = [],
        test: @escaping @Sendable ((repeat each Input)) async throws -> Void
    ) async -> FuzzResult<repeat each Input> {
        let startTime = dateClient.now()
        // TODO: I don't think this even makes sense. Current version is based on coverage counters
        // which should be 0 at this point.
        let schemaVersion = CorpusSchema.currentVersion()
        let corpus: CorpusClient<repeat each Input> = corpusRegistry.get(schemaVersion: schemaVersion)
        var failures: [(input: (repeat each Input), error: Error)] = []
        var hangs: [(input: (repeat each Input), timeout: Duration)] = []
        var iterationsSinceNewCoverage = 0
        var totalMutations = 0
        var totalGenerations = 0
        var totalDiscoveries = 0

        // Initialize event-based plugin dispatcher
        var dispatcher = EventBasedPluginDispatcher(plugins: config.plugins)

        // Build seed queue: default seeds + user-provided additional seeds
        // Using Deque for O(1) removeFirst() instead of Array's O(n)
//        var seedQueue = Deque(additionalSeeds + mutatorSeeds())

//        // Dispatch start event to plugins
//        let startContext = PluginEvent<repeat each Input>.StartContext(
//            maxIterations: config.maxIterations,
//            maxDuration: config.maxDuration,
//            batchSize: config.mutationBatchSize,
//            corpusMode: config.corpusMode,
//            seedCount: seedQueue.count
//        )
//        _ = try? await dispatcher.dispatch(event: PluginEvent<repeat each Input>.start(startContext))

//        let perTimeout = config.perInputTimeout
        let verbose = config.verbose

        // Capture client before loop to avoid @Dependency lookup overhead in hot path
        let coverageClient = coverageCounters
        let allSeeds = additionalSeeds + mutatorSeeds()

        // Early exit if no seeds and no way to generate inputs
        if allSeeds.isEmpty {
            if config.verbose {
                print("[Fuzz] No seeds and no mutations possible - exiting early")
            }
            return .empty
        }

        let stateMachine = try! await FuzzStateMachine(
            seeds: allSeeds,
            pluginDispatcher: dispatcher,
            config: config,
            startTime: startTime,
            randomInputGenerator: mutatorGenerate,
            mutationGenerator: mutatorMutate,
            test: test
        )

        try! await stateMachine.waitForCompletion()

//        // Unified fuzzing loop: seeds and mutations processed together
//        var iteration = 0
//        var stopReason: FuzzStats.StopReason = .iterationLimit
//        let batchSize = config.mutationBatchSize

//        while iteration < config.maxIterations {
//            // Check stopping conditions before generating batch
//            if Duration.seconds(dateClient.now().timeIntervalSince(startTime)) >= config.maxDuration {
//                if config.verbose {
//                    print("[Fuzz] Time limit reached after \(iteration) iterations")
//                }
//                stopReason = .timeLimit
//                break
//            }

            // Generate batch of inputs from current corpus state
//            let remainingIterations = config.maxIterations - iteration
//            let currentBatchSize = min(batchSize, remainingIterations)
//            var batch: [BatchEntry<repeat each Input>] = []
//            batch.reserveCapacity(currentBatchSize)

//            // Form a batch by taking from seed queue (generate if empty)
//            for _ in 0..<currentBatchSize {
//                // If queue is empty, generate fresh random input
//                if seedQueue.isEmpty {
//                    seedQueue.append(mutatorGenerate())
//                    totalGenerations += 1
//                }
//
//                // Take first item from queue
//                let input = seedQueue.removeFirst()
//
//                batch.append(BatchEntry(
//                    input: input,
//                    isMutation: false
//                ))
//            }

            // Run batch in parallel using withTaskGroup
            // Each task gets isolated coverage via swift_task_getCurrent()
//            let batchResults = await withTaskGroup(
//                of: BatchTestResult.self,
//                returning: [BatchTestResult].self
//            ) { group in
//                for (index, entry) in batch.enumerated() {
//                    group.addTask {
////                        // Begin measurement context - this pre-warms caches and creates isolated coverage map
////                        let context = coverageClient.beginMeasurement()
////                        defer { coverageClient.endMeasurement(context) }
////
////                        var testError: (any Error)?
////                        var timedOut = false
////
////                        do {
////                            if let timeout = perTimeout {
////                                timedOut = try await runWithTimeout(timeout: timeout) {
////                                    try await test(entry.input)
////                                }
////                            } else {
////                                try await test(entry.input)
////                            }
////                        } catch {
////                            testError = error
////                        }
//
////                        // Get coverage snapshot using context-aware API (O(1) even after task hop)
////                        let signature: CoverageSignature
////                        do {
////                            let sparse = try coverageClient.snapshotCoveredArraysWithContext(context)
////                            signature = CoverageSignature(sparse: sparse)
////                        } catch SanCovCounters.Errors.coverageNotAvailable {
////                            fatalError("coverage required for fuzzing")
////                        } catch {
////                            fatalError("unknown error")
////                        }
////
////                        return BatchTestResult(
////                            index: index,
////                            signature: signature,
////                            error: testError,
////                            timedOut: timedOut
////                        )
//                    }
//                }
//
//                var results: [BatchTestResult] = []
//                for await result in group {
//                    results.append(result)
//                }
//                return results.sorted { $0.index < $1.index }
//            }

            // First pass: handle errors/hangs and collect coverage candidates
//            typealias CandidateEntry = Corpus<repeat each Input>.CandidateEntry
//            var candidates: [CandidateEntry] = []

//            for result in batchResults {
//                let entry = batch[result.index]

                // Handle test errors and hangs - failing inputs are "interesting" so queue mutations
//                if result.timedOut {
//                    let timeout = config.perInputTimeout ?? .seconds(0)
//                    hangs.append((entry.input, timeout))
//                    if verbose {
//                        print("[Fuzz] Hang detected: input timed out after \(timeout)s, iteration \(iteration + result.index + 1)")
//                    }
//                    // Queue mutations of hanging input to explore nearby failure space
//                    let mutations = mutatorMutate(entry.input)
//                    seedQueue.append(contentsOf: mutations)
//                    totalMutations += mutations.count
//                } else

//                if let error = result.error {
                    // Dispatch failureFound for immediate shrinking
//                    let failureContext = PluginEvent<repeat each Input>.FailureFoundContext(
//                        input: entry.input,
//                        test: test,
//                        failure: String(describing: error),
//                        sourceLocation: config.sourceLocation,
//                        coverageSignature: result.signature
//                    )
//
//                    let actions = (try? await dispatcher.dispatch(
//                        event: PluginEvent<repeat each Input>.failureFound(failureContext)
//                    )) ?? []

//                    let actionResult = executeActions(actions)

                    // Record first selected input (shrunk) or original if none
//                    if let firstSelected = actionResult.inputsToMutate.first {
//                        failures.append((input: firstSelected, error: error))
//                    } else {
//                        failures.append((input: entry.input, error: error))
//                    }

                    // Process action result (mutations, corpus inputs)
//                    _ = await processActionResult(
//                        actionResult,
//                        seedQueue: &seedQueue,
//                        totalMutations: &totalMutations,
//                        corpus: corpus,
//                        test: test,
//                        coverageClient: coverageClient
//                    )

                    // Queue mutations of original input to explore nearby failure space
//                    let mutations = mutatorMutate(entry.input)
//                    seedQueue.append(contentsOf: mutations)
//                    totalMutations += mutations.count
//                    if verbose {
//                        print("[Fuzz] Failure found, queued \(mutations.count) mutations to explore nearby")
//                    }
//                }
//
//                // Collect candidates for batch add
//                let signature = result.signature
//                candidates.append(CandidateEntry(input: entry.input, signature: signature))
//            }

            // Batch add all candidates in a single actor call
//            let addResults = await corpus.batchAddIfInteresting(candidates)
//
//            // Second pass: update counters, queue mutations, and dispatch iteration events
//            var candidateResultIdx = 0
//            var newPathsInBatch = 0
//            var shouldStopFromPlugin = false
//            var pluginStopReason: String?
//
//            for result in batchResults {
//                iteration += 1
//                iterationsSinceNewCoverage += 1
//
//                let wasAdded = addResults[candidateResultIdx]
//                let entry = batch[result.index]
//                candidateResultIdx += 1
//
//                if wasAdded {
//                    iterationsSinceNewCoverage = 0
//                    newPathsInBatch += 1
//                    totalDiscoveries += 1
//
//                    // Add mutations of interesting input to end of seed queue
//                    let mutations = mutatorMutate(entry.input)
//                    seedQueue.append(contentsOf: mutations)
//                    totalMutations += mutations.count
//
//                    if verbose {
//                        let count = await corpus.count()
//                        print("[Fuzz] New coverage! \(count) entries, iteration \(iteration), queued \(mutations.count) mutations")
//                    }
//                }
//
//                // Dispatch iteration event to plugins
//                let corpusSize = await corpus.count()
//                let elapsed = dateClient.now().timeIntervalSince(startTime)
//                let iterationContext = PluginEvent<repeat each Input>.IterationContext(
//                    iteration: iteration,
//                    discoveredNewCoverage: wasAdded,
//                    elapsed: elapsed,
//                    corpusSize: corpusSize
//                )
//
//                if let actions = try? await dispatcher.dispatch(event: PluginEvent<repeat each Input>.iteration(iterationContext)) {
//                    let actionResult = executeActions(actions)
//                    if actionResult.shouldStop {
//                        shouldStopFromPlugin = true
//                        pluginStopReason = actionResult.stopReason
//                    }
//                    // Note: queueInputs not handled during iteration to avoid modifying seedQueue during iteration
//                }
//
//                if shouldStopFromPlugin {
//                    break
//                }
//            }

            // Check if plugin requested stop
//            if shouldStopFromPlugin {
//                if verbose {
//                    print("[Fuzz] Plugin stopping condition triggered: \(pluginStopReason ?? "unknown")")
//                    print("[Fuzz] Stopping early at iteration \(iteration) (saved \(config.maxIterations - iteration) iterations)")
//                }
//                stopReason = .coveragePlateau
//                break
//            }

            // Dispatch batch complete event to plugins
//            let batchCorpusSize = await corpus.count()
//            let batchElapsed = dateClient.now().timeIntervalSince(startTime)
//            let batchContext = PluginEvent<repeat each Input>.BatchContext(
//                batchIndex: (iteration - batchResults.count) / batchSize,
//                batchSize: batchResults.count,
//                newPathsInBatch: newPathsInBatch,
//                totalCorpusSize: batchCorpusSize,
//                elapsed: batchElapsed,
//                failureCount: failures.count,
//                hangCount: hangs.count
//            )
//            _ = try? await dispatcher.dispatch(event: PluginEvent<repeat each Input>.batchComplete(batchContext))
//        }

        // Phase 3: Minimize corpus
        var finalCorpus = corpus
        let corpusCountBeforeMinimize = await corpus.count()
        if config.minimizeCorpus && corpusCountBeforeMinimize > 1 {
            let minimizedSnapshot = await corpus.minimized()
            finalCorpus = CorpusClient.live(corpus: Corpus(from: minimizedSnapshot))
            if config.verbose {
                let finalCount = await finalCorpus.count()
                print("[Fuzz] Minimized corpus: \(corpusCountBeforeMinimize) -> \(finalCount)")
            }
        }

        // Phase 4: Save corpus
        if let directory = corpusDirectory {
            do {
                let snapshotToSave = await finalCorpus.snapshot()
                try corpusPersistenceClient.save(snapshotToSave, to: directory)
                if config.verbose {
                    print("[Fuzz] Saved corpus to \(directory.path)")
                }
            } catch {
                if config.verbose {
                    print("[Fuzz] Failed to save corpus: \(error)")
                }
            }
        }

        let duration = dateClient.now().timeIntervalSince(startTime)

        // Report hang statistics if any were detected
        if !hangs.isEmpty && config.verbose {
            print("[Fuzz] Hang statistics: \(hangs.count) inputs caused timeouts")
        }

        let finalCorpusCount = await finalCorpus.count()
        let stats = FuzzStats(
            totalInputs: iteration,
            newPaths: finalCorpusCount,
            mutations: totalMutations,
            generations: totalGenerations,
            duration: duration,
            stopReason: stopReason,
            plateauStats: nil,
            failures: failures.count,
            hangs: hangs.count
        )

        // Dispatch end event to plugins for analysis
        let totalCoverage = await finalCorpus.totalCoverage()
        let totalCoveredIndices = totalCoverage.executedIndices

        let endContext = PluginEvent<repeat each Input>.EndContext(
            totalIterations: iteration,
            duration: duration,
            corpusSize: finalCorpusCount,
            failureCount: failures.count,
            hangCount: hangs.count,
            stopReason: stopReason,
            totalCoveredIndices: totalCoveredIndices,
            projectPath: config.projectPath,
            sourceLocation: config.sourceLocation
        )

        if let actions = try? await dispatcher.dispatch(event: PluginEvent<repeat each Input>.end(endContext)) {
            _ = executeActions(actions)
        }
        // Note: stop and queueInputs not relevant at end event

        let finalSnapshot = await finalCorpus.snapshot()
        return FuzzResult(
            corpus: finalSnapshot,
            failures: failures,
            stats: stats,
            wasRegression: false,
            coverageChanges: []
        )
    }

    // MARK: - Regression Mode

    private func runRegression(
        snapshot: CorpusSnapshot<repeat each Input>,
        test: @escaping @Sendable ((repeat each Input)) async throws -> Void
    ) async -> FuzzResult<repeat each Input> {
        let startTime = dateClient.now()
        var failures: [(input: (repeat each Input), error: Error)] = []
        var coverageChanges: [(input: (repeat each Input), expected: CoverageSignature, actual: CoverageSignature)] = []
        var needsRefuzz = false

        if config.verbose {
            print("[Regression] Running \(snapshot.count) saved inputs...")
        }

        for entry in snapshot.entries {
            // Begin measurement context for this entry
            let context = coverageCounters.beginMeasurement()
            defer { coverageCounters.endMeasurement(context) }

            var testError: Error?
            do {
                try await test(entry.input)
            } catch {
                testError = error
            }

            if let error = testError {
                failures.append((entry.input, error))
            }

            // Get coverage snapshot using context-aware API (O(1) even after task hop)
            do {
                let sparse = try coverageCounters.snapshotCoveredArraysWithContext(context)
                let actualSignature = CoverageSignature(sparse: sparse)
                if actualSignature != entry.signature {
                    coverageChanges.append((
                        input: entry.input,
                        expected: entry.signature,
                        actual: actualSignature
                    ))
                    needsRefuzz = true
                }
            } catch {
                fatalError("coverage needs to be enabled for fuzzing")
            }
        }

        // If coverage changed, re-fuzz
        if needsRefuzz {
            if config.verbose {
                print("[Regression] Coverage changed for \(coverageChanges.count) inputs, re-fuzzing...")
            }
            // Delete old corpus and re-fuzz
            if let directory = corpusDirectory {
                try? corpusPersistenceClient.delete(directory)
            }
            return await runFuzzing(test: test)
        }

        let duration = dateClient.now().timeIntervalSince(startTime)
        let stats = FuzzStats(
            totalInputs: snapshot.count,
            newPaths: 0,
            mutations: 0,
            generations: 0,
            duration: duration,
            stopReason: .regression,
            plateauStats: nil
        )

        // Dispatch end event to plugins for analysis
        if !config.plugins.isEmpty {
            var dispatcher = EventBasedPluginDispatcher(plugins: config.plugins)
            let totalCoveredIndices = snapshot.totalCoverage.executedIndices

            if config.verbose {
                print("[Regression] Running analysis: corpus covered \(totalCoveredIndices.count) edges, total edges: \(SanCovCounters.totalEdgeCount)")
            }

            let endContext = PluginEvent<repeat each Input>.EndContext(
                totalIterations: snapshot.count,
                duration: duration,
                corpusSize: snapshot.count,
                failureCount: failures.count,
                hangCount: 0,
                stopReason: .iterationLimit,
                totalCoveredIndices: totalCoveredIndices,
                projectPath: config.projectPath,
                sourceLocation: config.sourceLocation
            )

            if let actions = try? await dispatcher.dispatch(event: PluginEvent<repeat each Input>.end(endContext)) {
                _ = executeActions(actions)
            }
        }

        // Return the snapshot directly for the result
        return FuzzResult(
            corpus: snapshot,
            failures: failures,
            stats: stats,
            wasRegression: true,
            coverageChanges: coverageChanges
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
