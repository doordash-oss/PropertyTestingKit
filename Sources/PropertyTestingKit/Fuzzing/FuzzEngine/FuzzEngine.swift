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
    /// When nil, uses the type's Fuzzable conformance.
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
    private let mutatorSeeds: MutatorSeeds?
    private let mutatorMutate: MutatorMutate?

    public init(config: Config = Config(), corpusDirectory: URL? = nil) {
        self.config = config
        self.corpusDirectory = corpusDirectory
        self.mutatorSeeds = nil
        self.mutatorMutate = nil
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
        // Get seed arrays for each mutator
        var counts: [Int] = []
        (repeat counts.append((each mutators).seeds.count))

        // If any array is empty, return empty result
        guard !counts.contains(0) else { return [] }

        // Calculate total combinations
        let total = counts.reduce(1, *)
        var results: [(repeat each Input)] = []

        // Collect all seed arrays
        var allSeeds: [Any] = []
        (repeat allSeeds.append((each mutators).seeds))

        for i in 0..<total {
            // Calculate indices for this combination
            var indices: [Int] = []
            var remaining = i
            for count in counts.reversed() {
                indices.insert(remaining % count, at: 0)
                remaining /= count
            }

            // Build the tuple for this combination
            var indexIterator = indices.makeIterator()
            var seedArrayIterator = allSeeds.makeIterator()

            func getValue<U>(_: U.Type) -> U {
                let idx = indexIterator.next()!
                let seedArray = seedArrayIterator.next()! as! [U]
                return seedArray[idx]
            }

            let tuple: (repeat each Input) = (repeat getValue((each Input).self))
            results.append(tuple)
        }

        return results
    }

    /// Mutate an input using the provided mutators.
    private static func mutateWithMutators<each M: Mutator>(
        input: (repeat each Input),
        mutators: (repeat each M)
    ) -> [(repeat each Input)] where (repeat (each M).Value) == (repeat each Input) {
        var results: [(repeat each Input)] = []

        // Collect mutators into array for indexed access
        var mutatorArray: [Any] = []
        (repeat mutatorArray.append(each mutators))

        // For each component, try mutating it while keeping others the same
        var componentIndex = 0

        func tryMutateComponent<V: Sendable>(_ value: V, index: Int) {
            // Get the mutator for this component
            guard index < mutatorArray.count else { return }

            // We need to find the mutator that matches this type
            let mutator = mutatorArray[index]

            // Use type casting to call mutate
            if let typedMutator = mutator as? AnyMutator<V> {
                let mutations = typedMutator.mutate(value)
                for mutated in mutations {
                    if let newTuple = createMutatedTuple(input, mutating: index, with: mutated) {
                        results.append(newTuple)
                    }
                }
            } else {
                // Try to extract mutations dynamically
                // This handles cases where the mutator type doesn't exactly match AnyMutator
                for mutatorCandidate in mutatorArray {
                    if let singleMutator = mutatorCandidate as? SingleMutator<V> {
                        if mutatorArray.firstIndex(where: { ($0 as AnyObject) === (singleMutator as AnyObject) }) == index {
                            let mutations = singleMutator.mutate(value)
                            for mutated in mutations {
                                if let newTuple = createMutatedTuple(input, mutating: index, with: mutated) {
                                    results.append(newTuple)
                                }
                            }
                            break
                        }
                    }
                }
            }
        }

        // Iterate through each component
        componentIndex = 0
        (repeat { tryMutateComponent(each input, index: componentIndex); componentIndex += 1 }())

        return results
    }

    /// Create a mutated tuple at a specific index (static version).
    private static func createMutatedTuple<U>(
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
        // Start pre-warming the source location cache if gap detection is enabled.
        // This runs dladdr calls in the background so they complete by the time
        // gap detection needs them at the end of the fuzz run.
        if config.detectCoverageGaps {
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
                return await makeEmptyRegressionResult()
            }
            do {
                let savedSnapshot: CorpusSnapshot<repeat each Input> = try corpusPersistenceClient.loadSnapshot(from: directory)
                return await runRegression(snapshot: savedSnapshot, test: test)
            } catch {
                if config.verbose {
                    print("[Fuzz] Mode: regressionOnly - failed to load corpus: \(error)")
                }
                return await makeEmptyRegressionResult()
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

    /// Create an empty result for regression-only mode when no corpus exists.
    private func makeEmptyRegressionResult() async -> FuzzResult<repeat each Input> {
        let emptySnapshot = CorpusSnapshot<repeat each Input>(
            entries: [],
            schemaVersion: await CorpusSchema.currentVersion(),
            createdAt: dateClient.now(),
            updatedAt: dateClient.now(),
            totalCoverage: CoverageSignature(edges: [])
        )
        let emptyStats = FuzzStats(
            totalInputs: 0,
            newPaths: 0,
            mutations: 0,
            generations: 0,
            duration: 0,
            stopReason: .regression,
            plateauStats: nil
        )
        return FuzzResult(
            corpus: emptySnapshot,
            failures: [],
            stats: emptyStats,
            wasRegression: true,
            coverageChanges: [],
            coverageGapReport: nil
        )
    }

    // MARK: - Fuzz Mode

    private func runFuzzing(
        additionalSeeds: [(repeat each Input)] = [],
        test: @escaping @Sendable ((repeat each Input)) async throws -> Void
    ) async -> FuzzResult<repeat each Input> {
        let startTime = dateClient.now()
        let schemaVersion = await CorpusSchema.currentVersion()
        let corpus: CorpusClient<repeat each Input> = corpusRegistry.get(schemaVersion: schemaVersion)
        var failures: [(input: (repeat each Input), error: Error)] = []
        var hangs: [(input: (repeat each Input), timeout: TimeInterval)] = []
        var iterationsSinceNewCoverage = 0
        var totalMutations = 0
        var totalGenerations = 0

        // Initialize plateau detector for adaptive early stopping
        var plateauDetector = CoveragePlateauDetector(config: config.plateauConfig)

        // Phase 1: Seed with boundary values (defaults + user-provided)
        // Run seeds in parallel using Swift structured concurrency
        // Each Task gets its own coverage map via swift_task_getCurrent()
        let defaultSeeds = mutatorSeeds?() ?? cartesianProductFuzz()
        let seedInputs = defaultSeeds + additionalSeeds

        // Phase 1: Run seeds in parallel using withTaskGroup
        // Each task gets isolated coverage via swift_task_getCurrent()
        let perTimeout = config.perInputTimeout
        let verbose = config.verbose

        // Capture clients before loops to avoid @Dependency lookup overhead in hot path
        let coverageClient = coverageCounters
        let randomClient = random

        // Track seed execution time for auto-tuning batch size
        let seedPhaseStart = CFAbsoluteTimeGetCurrent()

        let seedResults = await withTaskGroup(
            of: SeedTaskResult.self,
            returning: [SeedTaskResult].self
        ) { group in
            for (index, input) in seedInputs.enumerated() {
                group.addTask {
                    // Begin measurement context - this pre-warms caches and creates isolated coverage map
                    guard let context = coverageClient.beginMeasurement() else {
                        return SeedTaskResult(
                            index: index,
                            signature: nil,
                            error: nil,
                            timedOut: false,
                            timeout: perTimeout ?? 0
                        )
                    }
                    defer { coverageClient.endMeasurement(context) }

                    // Reset coverage for this measurement context (uses context-aware API for O(1) performance after task hop)
                    coverageClient.resetWithContext(context)

                    // Run test with optional timeout
                    var testError: (any Error)?
                    var timedOut = false

                    if let timeout = perTimeout {
                        // Race test against timeout
                        do {
                            try await withThrowingTaskGroup(of: Void.self) { timeoutGroup in
                                timeoutGroup.addTask {
                                    try await test(input)
                                }
                                timeoutGroup.addTask {
                                    try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                                    throw HangDetectedError(timeout: timeout)
                                }
                                _ = try await timeoutGroup.next()
                                timeoutGroup.cancelAll()
                            }
                        } catch is HangDetectedError {
                            timedOut = true
                        } catch {
                            testError = error
                        }
                    } else {
                        // No timeout - run directly
                        do {
                            try await test(input)
                        } catch {
                            testError = error
                        }
                    }

                    // Get coverage snapshot using context-aware API (O(1) even after task hop)
                    let signature: CoverageSignature?
                    if let sparse = coverageClient.snapshotCoveredArraysWithContext(context) {
                        signature = CoverageSignature(sparse: sparse)
                    } else {
                        signature = nil
                    }

                    return SeedTaskResult(
                        index: index,
                        signature: signature,
                        error: testError,
                        timedOut: timedOut,
                        timeout: perTimeout ?? 0
                    )
                }
            }

            // Collect results
            var results: [SeedTaskResult] = []
            for await result in group {
                results.append(result)
            }
            // Sort by index to maintain deterministic corpus building
            return results.sorted { $0.index < $1.index }
        }

        _ = CFAbsoluteTimeGetCurrent() - seedPhaseStart  // seedExecutionTime (unused but kept for potential profiling)

        // First pass: handle errors/hangs and collect coverage candidates
        typealias SeedCandidateEntry = Corpus<repeat each Input>.CandidateEntry
        var seedCandidates: [SeedCandidateEntry] = []
        var seedCandidateIndices: [Int] = []

        for (resultIdx, result) in seedResults.enumerated() {
            let input = seedInputs[result.index]

            // Handle test failures and hangs
            if result.timedOut {
                hangs.append((input, result.timeout))
                if verbose {
                    print("[Fuzz] Hang detected in seed: input timed out after \(result.timeout)s")
                }
            } else if let error = result.error {
                failures.append((input, error))
            }

            // Collect candidates for batch add
            if let signature = result.signature {
                seedCandidates.append(SeedCandidateEntry(input: input, signature: signature, parentIndex: nil))
                seedCandidateIndices.append(resultIdx)
            }
        }

        // Batch add all seed candidates in a single actor call
        let seedAddResults = await corpus.batchAddIfInteresting(seedCandidates)

        // Second pass: update counters based on batch results
        for wasAdded in seedAddResults {
            if wasAdded {
                iterationsSinceNewCoverage = 0
                if verbose {
                    let count = await corpus.count()
                    print("[Fuzz] New coverage from seed: \(count) entries")
                }
            }
        }

        totalGenerations = seedInputs.count
        // Note: don't clear priorityMutationIndex - seeds may have set a priority to follow up on

        // Early exit if no seeds were processed and no mutations are possible
        // This prevents spinning until time limit when fuzz array is empty
        let canGenerateFresh = !(mutatorSeeds?() ?? cartesianProductFuzz()).isEmpty
        if await corpus.isEmpty() && !canGenerateFresh {
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
                failures: failures.count,
                hangs: hangs.count
            )
            let emptySnapshot = await corpus.snapshot()
            return FuzzResult(
                corpus: emptySnapshot,
                failures: failures,
                stats: stats,
                wasRegression: false,
                coverageChanges: [],
                coverageGapReport: nil
            )
        }

//        let fuzzLoopStart = CFAbsoluteTimeGetCurrent()
        // Phase 2: Coverage-guided fuzzing with batch parallelization
        var iteration = seedInputs.count
        var stopReason: FuzzStats.StopReason = .iterationLimit

        // Timing accumulators for profiling
        // var timeInMutation: Double = 0
        // var timeInTest: Double = 0
        // var timeInCoverage: Double = 0

        let batchSize = config.mutationBatchSize

        while iteration < config.maxIterations {
//            let batchStart = CFAbsoluteTimeGetCurrent()

            // Check stopping conditions before generating batch
            if dateClient.now().timeIntervalSince(startTime) >= config.maxDuration {
                if config.verbose {
                    print("[Fuzz] Time limit reached after \(iteration) iterations")
                }
                stopReason = .timeLimit
                break
            }

            if plateauDetector.hasPlateaued {
                if config.verbose {
                    print("[Fuzz] Coverage plateau detected: \(plateauDetector.summary(includeDetails: true))")
                    print("[Fuzz] Stopping early at iteration \(iteration) (saved \(config.maxIterations - iteration) iterations)")
                }
                stopReason = .coveragePlateau
                break
            }

            // Generate batch of inputs from current corpus state
            // Inputs and metadata stored in parallel arrays (structs can't contain parameter packs)
            let remainingIterations = config.maxIterations - iteration
            let currentBatchSize = min(batchSize, remainingIterations)
            var batchInputs: [(repeat each Input)] = []
            var batchMeta: [BatchEntryMeta] = []
            batchInputs.reserveCapacity(currentBatchSize)
            batchMeta.reserveCapacity(currentBatchSize)

            // Get corpus state once for the entire batch (1 actor hop instead of ~400)
            let corpusState = await corpus.batchState()

            for batchIdx in 0..<currentBatchSize {
                let input: (repeat each Input)
                let parentIndex: Int?
                var isMutation = false

                // Use cached randomClient to avoid @Dependency lookup overhead
                let shouldGenerate = corpusState.isEmpty || randomClient { rng in Double.random(in: 0..<1, using: &rng) } < config.generationRatio

                if shouldGenerate {
                    // Generate fresh input
                    let fuzzValues = mutatorSeeds?() ?? cartesianProductFuzz()
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
                    let mutations = mutatorMutate?(parent) ?? mutateInput(parent)

                    if let m = randomClient({ rng in mutations.randomElement(using: &rng) }) {
                        input = m
                        parentIndex = selectedIndex
                        totalMutations += 1
                        isMutation = true
                    } else {
                        // Mutations exhausted - fall back to generation
                        let fuzzValues = mutatorSeeds?() ?? cartesianProductFuzz()
                        guard let fuzzValue = randomClient({ rng in fuzzValues.randomElement(using: &rng) }) else {
                            continue
                        }
                        input = fuzzValue
                        parentIndex = nil
                        totalGenerations += 1
                    }
                }

                batchInputs.append(input)
                batchMeta.append(BatchEntryMeta(
                    index: batchIdx,
                    parentIndex: parentIndex,
                    isMutation: isMutation
                ))
            }

            // Skip if no inputs were generated
            guard !batchInputs.isEmpty else {
                iteration += 1
                continue
            }

            // let mutationEnd = CFAbsoluteTimeGetCurrent()
            // timeInMutation += mutationEnd - batchStart

            // Run batch in parallel using withTaskGroup
            // Each task gets isolated coverage via swift_task_getCurrent()
            // let testStart = CFAbsoluteTimeGetCurrent()
            let batchResults = await withTaskGroup(
                of: BatchTestResult.self,
                returning: [BatchTestResult].self
            ) { group in
                for (index, input) in batchInputs.enumerated() {
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

                        // Reset coverage using context-aware API (O(1) even after task hop)
                        coverageClient.resetWithContext(context)

                        var testError: (any Error)?
                        var timedOut = false

                        if let timeout = perTimeout {
                            do {
                                try await withThrowingTaskGroup(of: Void.self) { timeoutGroup in
                                    timeoutGroup.addTask {
                                        try await test(input)
                                    }
                                    timeoutGroup.addTask {
                                        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                                        throw HangDetectedError(timeout: timeout)
                                    }
                                    _ = try await timeoutGroup.next()
                                    timeoutGroup.cancelAll()
                                }
                            } catch is HangDetectedError {
                                timedOut = true
                            } catch {
                                testError = error
                            }
                        } else {
                            do {
                                try await test(input)
                            } catch {
                                testError = error
                            }
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

            // let testEnd = CFAbsoluteTimeGetCurrent()
            // timeInTest += testEnd - testStart

            // // Process results sequentially to update corpus and state
            // let coverageStart = CFAbsoluteTimeGetCurrent()

            // First pass: handle errors/hangs and collect coverage candidates
            typealias CandidateEntry = Corpus<repeat each Input>.CandidateEntry
            var candidates: [CandidateEntry] = []
            var candidateIndices: [Int] = []  // Track which batchResults have candidates

            for (resultIdx, result) in batchResults.enumerated() {
                let input = batchInputs[result.index]

                // Handle test errors and hangs
                if result.timedOut {
                    let timeout = config.perInputTimeout ?? 0
                    hangs.append((input, timeout))
                    if verbose {
                        print("[Fuzz] Hang detected: input timed out after \(timeout)s, iteration \(iteration + resultIdx + 1)")
                    }
                } else if let error = result.error {
                    failures.append((input, error))
                }

                // Collect candidates for batch add
                if let signature = result.signature {
                    let meta = batchMeta[result.index]
                    candidates.append(CandidateEntry(input: input, signature: signature, parentIndex: meta.parentIndex))
                    candidateIndices.append(resultIdx)
                }
            }

            // Batch add all candidates in a single actor call
            let addResults = await corpus.batchAddIfInteresting(candidates)

            // Second pass: update counters based on batch results
            var candidateResultIdx = 0
            for result in batchResults {
                iteration += 1
                iterationsSinceNewCoverage += 1

                if result.signature != nil {
                    let wasAdded = addResults[candidateResultIdx]
                    candidateResultIdx += 1

                    // Record discovery status for plateau detection
                    plateauDetector.record(discoveredNewCoverage: wasAdded)

                    if wasAdded {
                        iterationsSinceNewCoverage = 0

                        if verbose {
                            let count = await corpus.count()
                            print("[Fuzz] New coverage! \(count) entries, iteration \(iteration)")
                        }
                    }
                } else {
                    plateauDetector.record(discoveredNewCoverage: false)
                }
            }

            // let coverageEnd = CFAbsoluteTimeGetCurrent()
            // timeInCoverage += coverageEnd - coverageStart
        }

        // let fuzzLoopEnd = CFAbsoluteTimeGetCurrent()
        // print("[Timing] Fuzz loop: \(String(format: "%.3f", fuzzLoopEnd - fuzzLoopStart))s (\(iteration) iterations)")
        // print("[Timing]   - Mutation: \(String(format: "%.3f", timeInMutation))s")
        // print("[Timing]   - Test execution: \(String(format: "%.3f", timeInTest))s")
        // print("[Timing]   - Coverage processing: \(String(format: "%.3f", timeInCoverage))s")

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
        // let saveEnd = CFAbsoluteTimeGetCurrent()
        // print("[Timing] Save corpus: \(String(format: "%.3f", saveEnd - saveStart))s")

        let duration = dateClient.now().timeIntervalSince(startTime)

        // Report plateau detector statistics if verbose
        if config.verbose && config.plateauConfig.enabled {
            let pStats = plateauDetector.stats()
            print("[Fuzz] Plateau detector: \(pStats.totalDiscoveries) discoveries in \(pStats.totalIterations) iterations")
            print("[Fuzz] Discovery rate: \(String(format: "%.4f", pStats.overallRate)) overall, \(String(format: "%.4f", pStats.windowRate)) recent")
        }

        // Report hang statistics if any were detected
        if !hangs.isEmpty && config.verbose {
            print("[Fuzz] Hang statistics: \(hangs.count) inputs caused timeouts")
        }

        let finalCorpusCount = await finalCorpus.count()
        let plateauStats = config.plateauConfig.enabled ? plateauDetector.stats() : nil
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

        // Detect coverage gaps if enabled
//        let gapStart = CFAbsoluteTimeGetCurrent()
        var coverageGapReport: CoverageGapReport?
        if config.detectCoverageGaps {
            let totalCoverage = await finalCorpus.totalCoverage()
            let totalCoveredIndices = totalCoverage.executedIndices
            let detector = CoverageGapDetector(config: config.coverageGapConfig)

            // if config.verbose {
            //     print("[Fuzz] Gap detection: corpus covered \(totalCoveredIndices.count) edges, total edges: \(SanCovCounters.totalEdgeCount)")
            // }

            coverageGapReport = await detector.detect(from: totalCoveredIndices, projectPath: config.projectPath)

            // if config.verbose, let report = coverageGapReport {
            //     print("[Fuzz] \(report.detailedSummary)")
            // }
        }
        // let gapEnd = CFAbsoluteTimeGetCurrent()
        // print("[Timing] Gap detection: \(String(format: "%.3f", gapEnd - gapStart))s")

        let finalSnapshot = await finalCorpus.snapshot()
        return FuzzResult(
            corpus: finalSnapshot,
            failures: failures,
            stats: stats,
            wasRegression: false,
            coverageChanges: [],
            coverageGapReport: coverageGapReport
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

            // Reset coverage using context-aware API (O(1) even after task hop)
            coverageCounters.resetWithContext(context)

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

        // Detect coverage gaps if enabled
        var coverageGapReport: CoverageGapReport?
        if config.detectCoverageGaps {
            let totalCoveredIndices = snapshot.totalCoverage.executedIndices
            let detector = CoverageGapDetector(config: config.coverageGapConfig)

            if config.verbose {
                print("[Regression] Gap detection: corpus covered \(totalCoveredIndices.count) edges, total edges: \(SanCovCounters.totalEdgeCount)")
            }

            coverageGapReport = await detector.detect(from: totalCoveredIndices, projectPath: config.projectPath)

            if config.verbose, let report = coverageGapReport {
                print("[Regression] \(report.detailedSummary)")
            }
        }

        // Return the snapshot directly for the result
        return FuzzResult(
            corpus: snapshot,
            failures: failures,
            stats: stats,
            wasRegression: true,
            coverageChanges: coverageChanges,
            coverageGapReport: coverageGapReport
        )
    }

    // MARK: - Variadic Helpers

    /// Generate the cartesian product of fuzz values for all input types.
    private func cartesianProductFuzz() -> [(repeat each Input)] {
        // Get fuzz arrays for each type
        var counts: [Int] = []
        (repeat counts.append((each Input).fuzz.count))

        // If any array is empty, return empty result
        guard !counts.contains(0) else { return [] }

        // Calculate total combinations
        let total = counts.reduce(1, *)
        var results: [(repeat each Input)] = []

        for i in 0..<total {
            // Calculate indices for this combination
            var indices: [Int] = []
            var remaining = i
            for count in counts.reversed() {
                indices.insert(remaining % count, at: 0)
                remaining /= count
            }

            // Build the tuple for this combination
            var indexIterator = indices.makeIterator()
            func getValue<U: Fuzzable>(_: U.Type) -> U {
                U.fuzz[indexIterator.next()!]
            }

            let tuple: (repeat each Input) = (repeat getValue((each Input).self))
            results.append(tuple)
        }

        return results
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
    private func singleComponentMutations(_ input: (repeat each Input)) -> [(repeat each Input)] {
        var results: [(repeat each Input)] = []
        var componentIndex = 0

        func tryMutate<U: Fuzzable>(_ value: U, atIndex index: Int) {
            let mutations = value.mutate()
            for mutated in mutations {
                if let newTuple = createMutatedTuple(input, mutating: index, with: mutated) {
                    results.append(newTuple)
                }
            }
            componentIndex += 1
        }

        componentIndex = 0
        (repeat tryMutate(each input, atIndex: componentIndex))

        return results
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
