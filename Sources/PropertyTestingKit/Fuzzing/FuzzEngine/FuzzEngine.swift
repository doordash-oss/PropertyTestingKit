//
//  FuzzEngine.swift
//  PropertyTestingKit
//
//  Coverage-guided fuzzing engine that combines mutation and generation.
//

import Dependencies
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
/// 1. Start with boundary values from `Fuzzable.fuzz`
/// 2. Run each input, capture coverage signature
/// 3. If signature is new, add to corpus
/// 4. Select corpus entries for mutation (energy-based)
/// 5. Mutate inputs, repeat
/// 6. Stop when: iteration limit, time limit, or coverage plateau
/// 7. Minimize corpus, save to disk
///
public actor FuzzEngine<each Input: Fuzzable & Codable & Sendable> {
    /// Type-erased mutator functions for each input component.
    public typealias MutatorSeeds = @Sendable () -> [(repeat each Input)]
    public typealias MutatorMutate = @Sendable ((repeat each Input)) -> [(repeat each Input)]

    @Dependency(\.dateClient) private var dateClient
    @Dependency(\.random) private var random
    @Dependency(\.corpusPersistence) private var corpusPersistenceClient
    @Dependency(\.coverageCounters) private var coverageCounters
    @Dependency(\.corpusRegistry) private var corpusRegistry

    // MARK: - Random Helpers (use injected RNG for determinism)

    /// Generate a random Double in the given range using the injected RNG.
    private func randomDouble(in range: Range<Double>) -> Double {
        random { rng in
            Double.random(in: range, using: &rng)
        }
    }

    /// Select a random element from a collection using the injected RNG.
    private func randomElement<C: Collection & Sendable>(from collection: C) -> C.Element? where C.Element: Sendable {
        random { rng in
            collection.randomElement(using: &rng)
        }
    }

    private let config: Config
    private let corpusDirectory: URL?
    private let mutatorSeeds: MutatorSeeds
    private let mutatorMutate: MutatorMutate

    /// Initialize with default mutators derived from `Fuzzable` conformance.
    ///
    /// - Parameters:
    ///   - config: Fuzzing configuration.
    ///   - corpusDirectory: Where to save/load the corpus.
    public init(config: Config = Config(), corpusDirectory: URL? = nil) {
        self.init(
            mutators: (repeat DefaultMutator<each Input>()),
            config: config,
            corpusDirectory: corpusDirectory
        )
    }

    /// Initialize with custom mutators.
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
        if config.analysisPlugins.contains(where: { $0 is CoverageGapPlugin }) {
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
        let schemaVersion = CorpusSchema.currentVersion()
        let corpus: CorpusClient<repeat each Input> = corpusRegistry.get(schemaVersion: schemaVersion)
        var failures: [(input: (repeat each Input), error: Error)] = []
        var hangs: [(input: (repeat each Input), timeout: Duration)] = []
        var iterationsSinceNewCoverage = 0
        var totalMutations = 0
        var totalGenerations = 0
        var totalDiscoveries = 0

        // Initialize plugin manager for lifecycle events and stopping conditions
        var pluginManager = FuzzPluginManager(
            observerPlugins: config.observerPlugins,
            stoppingPlugins: config.stoppingPlugins,
            analysisPlugins: config.analysisPlugins,
            shrinkingPlugin: config.shrinkingPlugin
        )

        // Build seed queue: default seeds + user-provided additional seeds
        let defaultSeeds = mutatorSeeds()
        var seedQueue = defaultSeeds + additionalSeeds
        let initialSeedCount = seedQueue.count

        // Notify observers that fuzzing has started
        let startContext = FuzzPluginContext.StartContext(
            maxIterations: config.maxIterations,
            maxDuration: config.maxDuration,
            batchSize: config.mutationBatchSize,
            corpusMode: config.corpusMode,
            seedCount: initialSeedCount
        )
        await pluginManager.notifyStart(context: startContext)

        let perTimeout = config.perInputTimeout
        let verbose = config.verbose

        // Capture clients before loops to avoid @Dependency lookup overhead in hot path
        let coverageClient = coverageCounters
        let randomClient = random

        // Early exit if no seeds and no way to generate inputs
        if seedQueue.isEmpty && mutatorSeeds().isEmpty {
            if config.verbose {
                print("[Fuzz] No seeds and no mutations possible - exiting early")
            }
            let duration = dateClient.now().timeIntervalSince(startTime)
            let stats = FuzzStats(
                totalInputs: 0,
                newPaths: 0,
                mutations: 0,
                generations: 0,
                duration: duration,
                stopReason: .noSeedsAvailable,
                failures: 0,
                hangs: 0
            )
            let emptySnapshot = await corpus.snapshot()
            return FuzzResult(
                corpus: emptySnapshot,
                failures: failures,
                stats: stats,
                wasRegression: false,
                coverageChanges: []
            )
        }

        // Unified fuzzing loop: seeds and mutations processed together
        var iteration = 0
        var stopReason: FuzzStats.StopReason = .iterationLimit
        let batchSize = config.mutationBatchSize

        while iteration < config.maxIterations {
            // Check stopping conditions before generating batch
            if Duration.seconds(dateClient.now().timeIntervalSince(startTime)) >= config.maxDuration {
                if config.verbose {
                    print("[Fuzz] Time limit reached after \(iteration) iterations")
                }
                stopReason = .timeLimit
                break
            }

            // Check plugin-based stopping conditions
            let corpusSize = await corpus.count()
            let elapsed = dateClient.now().timeIntervalSince(startTime)
            // Compute recent discovery rate from the last ~100 iterations
            let windowSize = min(100, iteration)
            let recentRate = windowSize > 0 ? Double(totalDiscoveries) / Double(iteration) : 0.0
            let stoppingContext = FuzzPluginContext.StoppingContext(
                iteration: iteration,
                elapsed: elapsed,
                corpusSize: corpusSize,
                recentDiscoveryRate: recentRate,
                totalDiscoveries: totalDiscoveries,
                iterationsSinceLastDiscovery: iterationsSinceNewCoverage
            )

            if let pluginStopReason = pluginManager.shouldStop(context: stoppingContext) {
                if config.verbose {
                    print("[Fuzz] Plugin stopping condition triggered: \(pluginStopReason)")
                    print("[Fuzz] Stopping early at iteration \(iteration) (saved \(config.maxIterations - iteration) iterations)")
                }
                // Map known reasons to FuzzStats.StopReason
                if pluginStopReason == "coverage_plateau" {
                    stopReason = .coveragePlateau
                } else {
                    // For custom reasons, use coverage_plateau as the enum value
                    // but the actual reason is logged above
                    stopReason = .coveragePlateau
                }
                break
            }

            // Generate batch of inputs from current corpus state
            let remainingIterations = config.maxIterations - iteration
            let currentBatchSize = min(batchSize, remainingIterations)
            var batch: [BatchEntry<repeat each Input>] = []
            batch.reserveCapacity(currentBatchSize)

            // Get corpus state once for the entire batch (1 actor hop instead of ~400)
            let corpusState = await corpus.batchState()

            for _ in 0..<currentBatchSize {
                let input: (repeat each Input)
                let parentIndex: Int?
                var isMutation = false

                // Priority 1: Consume from seed queue
                if !seedQueue.isEmpty {
                    input = seedQueue.removeFirst()
                    parentIndex = nil
                    totalGenerations += 1
                } else {
                    // Priority 2: Generate or mutate based on ratio
                    // Use cached randomClient to avoid @Dependency lookup overhead
                    let shouldGenerate = corpusState.isEmpty || randomClient { rng in Double.random(in: 0..<1, using: &rng) } < config.generationRatio

                    if shouldGenerate {
                        // Generate fresh input
                        let fuzzValues = mutatorSeeds()
                        guard let fuzzValue = randomClient({ rng in fuzzValues.randomElement(using: &rng) }) else {
                            continue
                        }
                        input = fuzzValue
                        parentIndex = nil
                        totalGenerations += 1
                    } else {
                        // Mutate existing corpus entry
                        let selectedIndex = corpusState.selectForMutation()!

                        let parent = corpusState.entries[selectedIndex].input
                        let mutations = mutatorMutate(parent)

                        if let m = randomClient({ rng in mutations.randomElement(using: &rng) }) {
                            input = m
                            parentIndex = selectedIndex
                            totalMutations += 1
                            isMutation = true
                        } else {
                            // Mutations exhausted - fall back to generation
                            let fuzzValues = mutatorSeeds()
                            guard let fuzzValue = randomClient({ rng in fuzzValues.randomElement(using: &rng) }) else {
                                continue
                            }
                            input = fuzzValue
                            parentIndex = nil
                            totalGenerations += 1
                        }
                    }
                }

                batch.append(BatchEntry(
                    input: input,
                    parentIndex: parentIndex,
                    isMutation: isMutation
                ))
            }

            // Skip if no inputs were generated
            guard !batch.isEmpty else {
                iteration += 1
                continue
            }

            // Run batch in parallel using withTaskGroup
            // Each task gets isolated coverage via swift_task_getCurrent()
            let batchResults = await withTaskGroup(
                of: BatchTestResult.self,
                returning: [BatchTestResult].self
            ) { group in
                for (index, entry) in batch.enumerated() {
                    group.addTask {
                        // Begin measurement context - this pre-warms caches and creates isolated coverage map
                        guard let context = coverageClient.beginMeasurement() else {
                            return BatchTestResult(
                                index: index,
                                signature: nil,
                                error: nil,
                                timedOut: false
                            )
                        }
                        defer { coverageClient.endMeasurement(context) }

                        var testError: (any Error)?
                        var timedOut = false

                        do {
                            if let timeout = perTimeout {
                                timedOut = try await runWithTimeout(timeout: timeout) {
                                    try await test(entry.input)
                                }
                            } else {
                                try await test(entry.input)
                            }
                        } catch {
                            testError = error
                        }

                        // Get coverage snapshot using context-aware API (O(1) even after task hop)
                        let signature: CoverageSignature?
                        if let sparse = coverageClient.snapshotCoveredArraysWithContext(context) {
                            signature = CoverageSignature(sparse: sparse)
                        } else {
                            signature = nil
                        }

                        return BatchTestResult(
                            index: index,
                            signature: signature,
                            error: testError,
                            timedOut: timedOut
                        )
                    }
                }

                var results: [BatchTestResult] = []
                for await result in group {
                    results.append(result)
                }
                return results.sorted { $0.index < $1.index }
            }

            // First pass: handle errors/hangs and collect coverage candidates
            typealias CandidateEntry = Corpus<repeat each Input>.CandidateEntry
            var candidates: [CandidateEntry] = []
            var candidateIndices: [Int] = []  // Track which batchResults have candidates

            for (resultIdx, result) in batchResults.enumerated() {
                let entry = batch[result.index]

                // Handle test errors and hangs
                if result.timedOut {
                    let timeout = config.perInputTimeout ?? .seconds(0)
                    hangs.append((entry.input, timeout))
                    if verbose {
                        print("[Fuzz] Hang detected: input timed out after \(timeout)s, iteration \(iteration + resultIdx + 1)")
                    }
                } else if let error = result.error {
                    failures.append((entry.input, error))
                }

                // Collect candidates for batch add
                if let signature = result.signature {
                    candidates.append(CandidateEntry(input: entry.input, signature: signature, parentIndex: entry.parentIndex))
                    candidateIndices.append(resultIdx)
                }
            }

            // Batch add all candidates in a single actor call
            let addResults = await corpus.batchAddIfInteresting(candidates)

            // Second pass: update counters based on batch results
            var candidateResultIdx = 0
            var newPathsInBatch = 0
            for result in batchResults {
                iteration += 1
                iterationsSinceNewCoverage += 1

                if result.signature != nil {
                    let wasAdded = addResults[candidateResultIdx]
                    candidateResultIdx += 1

                    // Record discovery status for stopping plugins
                    pluginManager.recordIteration(discoveredNewCoverage: wasAdded)

                    if wasAdded {
                        iterationsSinceNewCoverage = 0
                        newPathsInBatch += 1
                        totalDiscoveries += 1

                        if verbose {
                            let count = await corpus.count()
                            print("[Fuzz] New coverage! \(count) entries, iteration \(iteration)")
                        }
                    }
                } else {
                    pluginManager.recordIteration(discoveredNewCoverage: false)
                }
            }

            // Notify observers that batch completed
            let batchCorpusSize = await corpus.count()
            let batchElapsed = dateClient.now().timeIntervalSince(startTime)
            let batchContext = FuzzPluginContext.BatchContext(
                batchIndex: (iteration - batchResults.count) / batchSize,
                batchSize: batchResults.count,
                newPathsInBatch: newPathsInBatch,
                totalCorpusSize: batchCorpusSize,
                elapsed: batchElapsed,
                failureCount: failures.count,
                hangCount: hangs.count
            )
            await pluginManager.notifyBatchComplete(context: batchContext)
        }

        // Phase 3: Minimize corpus
        // let minimizeStart = CFAbsoluteTimeGetCurrent()
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
        // let minimizeEnd = CFAbsoluteTimeGetCurrent()
        // print("[Timing] Minimize corpus: \(String(format: "%.3f", minimizeEnd - minimizeStart))s")

        // Phase 4: Save corpus
        // let saveStart = CFAbsoluteTimeGetCurrent()
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

        // Report stopping plugin statistics if verbose
        if config.verbose && pluginManager.hasStoppingPlugins {
            let stoppingStats = pluginManager.stoppingStats()
            for stats in stoppingStats {
                let details = stats.details.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
                print("[Fuzz] \(stats.pluginId): \(details)")
            }
        }

        // Report hang statistics if any were detected
        if !hangs.isEmpty && config.verbose {
            print("[Fuzz] Hang statistics: \(hangs.count) inputs caused timeouts")
        }

        let finalCorpusCount = await finalCorpus.count()
        // Get plateau stats from the plateau detector plugin if present
        let plateauStats = pluginManager.getPlateauStats()
        let stats = FuzzStats(
            totalInputs: iteration,
            newPaths: finalCorpusCount,
            mutations: totalMutations,
            generations: totalGenerations,
            duration: duration,
            stopReason: stopReason,
            plateauStats: plateauStats,
            failures: failures.count,
            hangs: hangs.count
        )

        // Run analysis plugins
        let totalCoverage = await finalCorpus.totalCoverage()
        let totalCoveredIndices = totalCoverage.executedIndices

        let analysisContext = FuzzPluginContext.AnalysisContext(
            totalCoveredIndices: totalCoveredIndices,
            corpusSize: finalCorpusCount,
            duration: duration,
            projectPath: config.projectPath
        )

        let analysisReports = await pluginManager.runAnalysis(context: analysisContext)

        // Notify observers that fuzzing has ended
        let endContext = FuzzPluginContext.EndContext(
            totalIterations: iteration,
            duration: duration,
            corpusSize: finalCorpusCount,
            failureCount: failures.count,
            hangCount: hangs.count,
            stopReason: stopReason
        )
        await pluginManager.notifyEnd(context: endContext)

        let finalSnapshot = await finalCorpus.snapshot()
        return FuzzResult(
            corpus: finalSnapshot,
            failures: failures,
            stats: stats,
            wasRegression: false,
            coverageChanges: [],
            analysisReports: analysisReports
        )
    }

    // MARK: - Regression Mode

    private func runRegression(
        snapshot: CorpusSnapshot<repeat each Input>,
        test: @escaping @Sendable ((repeat each Input)) async throws -> Void
    ) async -> FuzzResult<repeat each Input> {
        @Dependency(\.coverageCounters) var coverageCounters

        let startTime = dateClient.now()
        var failures: [(input: (repeat each Input), error: Error)] = []
        var coverageChanges: [(input: (repeat each Input), expected: CoverageSignature, actual: CoverageSignature)] = []
        var needsRefuzz = false

        if config.verbose {
            print("[Regression] Running \(snapshot.count) saved inputs...")
        }

        for entry in snapshot.entries {
            // Begin measurement context for this entry
            guard let context = coverageCounters.beginMeasurement() else { continue }
            defer { coverageCounters.endMeasurement(context) }

            // No reset needed - map is already zero from calloc in beginMeasurement

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
            if let sparse = coverageCounters.snapshotCoveredArraysWithContext(context) {
                let actualSignature = CoverageSignature(sparse: sparse)
                if actualSignature != entry.signature {
                    coverageChanges.append((
                        input: entry.input,
                        expected: entry.signature,
                        actual: actualSignature
                    ))
                    needsRefuzz = true
                }
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

        // Run analysis plugins if any configured
        var analysisReports: [AnyAnalysisReport] = []
        if !config.analysisPlugins.isEmpty {
            let pluginManager = FuzzPluginManager(
                observerPlugins: [],
                stoppingPlugins: [],
                analysisPlugins: config.analysisPlugins,
                shrinkingPlugin: config.shrinkingPlugin
            )

            let totalCoveredIndices = snapshot.totalCoverage.executedIndices

            if config.verbose {
                print("[Regression] Running analysis: corpus covered \(totalCoveredIndices.count) edges, total edges: \(SanCovCounters.totalEdgeCount)")
            }

            let analysisContext = FuzzPluginContext.AnalysisContext(
                totalCoveredIndices: totalCoveredIndices,
                corpusSize: snapshot.count,
                duration: duration,
                projectPath: config.projectPath
            )

            analysisReports = await pluginManager.runAnalysis(context: analysisContext)

            if config.verbose {
                for report in analysisReports {
                    print("[Regression] \(report.summary)")
                }
            }
        }

        // Return the snapshot directly for the result
        return FuzzResult(
            corpus: snapshot,
            failures: failures,
            stats: stats,
            wasRegression: true,
            coverageChanges: coverageChanges,
            analysisReports: analysisReports
        )
    }

    // MARK: - Variadic Helpers

    /// Generate the cartesian product of fuzz values for all input types.
    private func cartesianProductFuzz() -> [(repeat each Input)] {
        cartesianProduct(repeat (each Input).fuzz)
    }

    /// Mutate a variadic input by randomly selecting one component to mutate.
    private func mutateInput(_ input: (repeat each Input)) -> [(repeat each Input)] {
        // Collect all possible mutations
        var results: [(repeat each Input)] = []

        // Strategy 1: Single-component mutations (original behavior)
        var componentIndex = 0
        func tryMutate<U: Fuzzable>(_ value: U, atIndex index: Int) {
            let mutations = value.mutate()
            for mutated in mutations {
                // Create a new tuple with this component mutated
                if let newTuple = createMutatedTuple(input, mutating: index, with: mutated) {
                    results.append(newTuple)
                }
            }
            componentIndex += 1
        }

        componentIndex = 0
        (repeat tryMutate(each input, atIndex: componentIndex))

        // Strategy 2: Multi-component mutations (mutate 2 components together)
        results.append(contentsOf: multiComponentMutations(input))

        // Strategy 3: Arithmetic relationship mutations for (Int, Int) pairs
        results.append(contentsOf: arithmeticRelationshipMutations(input))

        return results
    }

    /// Generate mutations where multiple components change together.
    /// This helps find correlated input combinations.
    private func multiComponentMutations(_ input: (repeat each Input)) -> [(repeat each Input)] {
        var results: [(repeat each Input)] = []

        // Extract values into arrays for manipulation
        var values: [Any] = []
        (repeat values.append(each input))

        guard values.count >= 2 else { return [] }

        // For each pair of components, try mutating both
        for i in 0..<values.count {
            for j in (i + 1)..<values.count {
                // Try swapping values if they're the same type
                if type(of: values[i]) == type(of: values[j]) {
                    if let newTuple = createSwappedTuple(input, swapping: i, with: j) {
                        results.append(newTuple)
                    }
                }
            }
        }

        return results
    }

    /// Generate arithmetic relationship mutations for Int pairs.
    /// Tries relationships like b = a*k + c that help crack checksum-style conditions.
    private func arithmeticRelationshipMutations(_ input: (repeat each Input)) -> [(repeat each Input)] {
        var results: [(repeat each Input)] = []

        // Extract values to find Int pairs
        var values: [Any] = []
        var indices: [Int] = []
        var componentIdx = 0

        func collectValue<V>(_ value: V) {
            values.append(value)
            indices.append(componentIdx)
            componentIdx += 1
        }
        (repeat collectValue(each input))

        // Find all Int values and their indices
        var intPairs: [(index: Int, value: Int)] = []
        for (idx, value) in zip(indices, values) {
            if let intVal = value as? Int {
                intPairs.append((idx, intVal))
            }
        }

        // For each pair of Ints, generate relationship-based mutations
        guard intPairs.count >= 2 else { return [] }

        for i in 0..<intPairs.count {
            for j in (i + 1)..<intPairs.count {
                let (idxA, a) = intPairs[i]
                let (idxB, _) = intPairs[j]

                // Generate b values based on relationships with a
                let derivedBValues = arithmeticDerivations(from: a)

                for newB in derivedBValues {
                    if let newTuple = createMutatedTuple(input, mutating: idxB, with: newB) {
                        results.append(newTuple)
                    }
                }

                // Also try the reverse: derive a from current b
                let (_, b) = intPairs[j]
                let derivedAValues = arithmeticDerivations(from: b)
                for newA in derivedAValues {
                    if let newTuple = createMutatedTuple(input, mutating: idxA, with: newA) {
                        results.append(newTuple)
                    }
                }
            }
        }

        return results
    }

    /// Generate single-component mutations (mutate one input field at a time).
    /// Uses parameter pack expansion to avoid type erasure.
    private func singleComponentMutations(_ input: (repeat each Input)) -> [(repeat each Input)] {
        let count = Self.inputCount(for: repeat each input)

        // For each position, create a tuple of arrays where:
        // - The mutated position contains all mutations from Fuzzable.mutate()
        // - Other positions contain just the original value wrapped in an array
        let positionsMutated: [(repeat [each Input])] = (0..<count).map { replacementIndex in
            var currentIndex = 0
            return (repeat {
                defer { currentIndex += 1 }
                if currentIndex == replacementIndex {
                    return (each input).mutate()
                } else {
                    return [(each input)]
                }
            }())
        }

        // Use cartesianProduct to expand each position's arrays into full tuples
        return positionsMutated.flatMap(cartesianProduct)
    }

    /// Generate derived values based on common arithmetic relationships.
    private func arithmeticDerivations(from value: Int) -> [Int] {
        var derived: [Int] = []

        // Linear relationships: b = a * k + c
        let multipliers = [1, 2, 3, 5, 7, 10]
        let offsets = [-3, -1, 0, 1, 3]

        for k in multipliers {
            for c in offsets {
                // b = a * k + c (with overflow protection)
                let (product, overflow1) = value.multipliedReportingOverflow(by: k)
                guard !overflow1 else { continue }
                let (result, overflow2) = product.addingReportingOverflow(c)
                guard !overflow2 else { continue }
                derived.append(result)
            }
        }

        // Also include the value itself, negation, and simple offsets
        derived.append(value)
        if value != Int.min { derived.append(-value) }
        if value != Int.max { derived.append(value + 1) }
        if value != Int.min { derived.append(value - 1) }

        return Array(Set(derived)) // Deduplicate
    }

    /// Create a tuple with two components swapped.
    private func createSwappedTuple(
        _ input: (repeat each Input),
        swapping indexA: Int,
        with indexB: Int
    ) -> (repeat each Input)? {
        var values: [Any] = []
        (repeat values.append(each input))

        guard indexA < values.count, indexB < values.count else { return nil }

        // Swap the values
        let temp = values[indexA]
        values[indexA] = values[indexB]
        values[indexB] = temp

        // Rebuild tuple
        var valueIterator = values.makeIterator()
        func nextValue<V>(_: V.Type) -> V {
            valueIterator.next()! as! V
        }

        let newTuple: (repeat each Input) = (repeat nextValue((each Input).self))
        return newTuple
    }

    /// Create a mutated tuple at a specific index.
    private func createMutatedTuple<U>(
        _ input: (repeat each Input),
        mutating targetIndex: Int,
        with newValue: U
    ) -> (repeat each Input)? {
        var currentIndex = 0

        func substituteIfNeeded<V: Fuzzable & Codable & Sendable>(_ value: V) -> V {
            defer { currentIndex += 1 }
            if currentIndex == targetIndex, let casted = newValue as? V {
                return casted
            }
            return value
        }

        let newTuple: (repeat each Input) = (repeat substituteIfNeeded(each input))
        return newTuple
    }
}

enum PluginEvent<each T> {
    case start(StartContext)
    case end(EndContext)
    case failureFound(FailureFoundContext)
    case iteration(IterationContext)

    struct FailureFoundContext {
        let input: (repeat each T)
        let test: @Sendable ((repeat each T)) async throws -> Void
        let failure: String
    }

    struct StartContext {

    }

    struct EndContext {
        /// Set of all covered edge indices.
        public let totalCoveredIndices: Set<Int>
        /// Project path for filtering (if configured).
        public let projectPath: String?
        public let testFilePath: String
        public let testFunctionLine: Int
    }

    struct IterationContext {
        public let discoveredNewCoverage: Bool
    }
}

enum FuzzPluginAction {
    case stop(StopContext)
    case mutate(MutationContext)

    struct StopContext {
        let reason: String
    }

    struct MutationContext {

    }
}


protocol EventBasedPlugin {
    mutating func handle<each T>(event: PluginEvent<repeat each T>) async throws -> [FuzzPluginAction]
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
