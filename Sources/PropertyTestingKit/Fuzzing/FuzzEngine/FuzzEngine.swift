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
/// ## Value Profile Guidance
///
/// When enabled and the test code is compiled with `-sanitize-coverage=trace-cmp`,
/// the engine also tracks comparison operand distances. Inputs that get "closer"
/// to satisfying comparisons (e.g., `x == 12345`) are prioritized for mutation,
/// even if they don't discover new edge coverage.
public final class FuzzEngine<each Input: Fuzzable & Codable & Sendable>: @unchecked Sendable {
    /// Type-erased mutator functions for each input component.
    /// When nil, uses the type's Fuzzable conformance.
    public typealias MutatorSeeds = () -> [(repeat each Input)]
    public typealias MutatorMutate = ((repeat each Input)) -> [(repeat each Input)]

    @Dependency(\.dateClient) var dateClient

    private let config: Config
    private let corpusDirectory: URL?
    private let mutatorSeeds: MutatorSeeds?
    private let mutatorMutate: MutatorMutate?

    /// Tracks comparison operand distances for value profile guidance.
    private let valueProfileTracker = ValueProfileTracker()

    /// Captures magic strings at runtime for dictionary-based mutation.
    private let stringDictionary = StringDictionary.shared

    /// Index of corpus entry that most recently made value profile progress.
    /// We prioritize mutating this entry to continue the chain of progress.
    private var priorityMutationIndex: Int?

    /// Saved targets from the test that made value profile progress.
    /// Used to continue the chain when mutating the priority entry.
    private var savedTargets: [ValueProfileTracker.ComparisonTarget] = []

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

        // IMPORTANT: Eagerly extract seeds and type-erased mutator array during init
        // to avoid capturing the parameter pack in escaping closures (which causes crashes
        // due to a Swift compiler bug with parameter pack capture in closures).
        let eagerlyCapturedSeeds = Self.extractMutatorSeeds(mutators: mutators)

        // Type-erase mutators into an array that can be safely stored
        var typeErasedMutators: [Any] = []
        (repeat typeErasedMutators.append(each mutators))
        let capturedMutators = typeErasedMutators

        self.mutatorSeeds = {
            eagerlyCapturedSeeds
        }

        self.mutatorMutate = { input in
            Self.mutateWithTypeErasedMutators(input: input, mutators: capturedMutators)
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
                    if let newTuple = createMutatedTupleStatic(input, mutating: index, with: mutated) {
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
                                if let newTuple = createMutatedTupleStatic(input, mutating: index, with: mutated) {
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

    /// Mutate an input using pre-captured type-erased mutators.
    /// This version takes an already-extracted [Any] array to avoid parameter pack capture issues.
    private static func mutateWithTypeErasedMutators(
        input: (repeat each Input),
        mutators mutatorArray: [Any]
    ) -> [(repeat each Input)] {
        var results: [(repeat each Input)] = []

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
                    if let newTuple = createMutatedTupleStatic(input, mutating: index, with: mutated) {
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
                                if let newTuple = createMutatedTupleStatic(input, mutating: index, with: mutated) {
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

    /// Create a mutated tuple at a specific index (static version for mutators).
    private static func createMutatedTupleStatic<U>(
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
        test: @escaping ((repeat each Input)) throws -> Void
    ) -> FuzzResult<repeat each Input> {
        // No lock needed - SanitizerCoverage uses task-keyed maps that provide
        // true per-task isolation, even when tasks share threads.
        runWithMode(additionalSeeds: additionalSeeds, test: test)
    }

    /// Internal dispatch based on corpus mode.
    private func runWithMode(
        additionalSeeds: [(repeat each Input)],
        test: @escaping ((repeat each Input)) throws -> Void
    ) -> FuzzResult<repeat each Input> {
        let corpusExists = corpusDirectory.map { Corpus<repeat each Input>.exists(at: $0) } ?? false

        // Handle refuzzReplace: delete corpus and fuzz fresh
        if config.corpusMode == .refuzzReplace {
            if corpusExists, let directory = corpusDirectory {
                if config.verbose {
                    print("[Fuzz] Mode: refuzzReplace - deleting existing corpus")
                }
                try? Corpus<repeat each Input>.delete(from: directory)
            }
            return runFuzzing(additionalSeeds: additionalSeeds, test: test)
        }

        // Handle refuzzExtend: load corpus as seeds and continue fuzzing
        if config.corpusMode == .refuzzExtend {
            var allSeeds = additionalSeeds
            if corpusExists, let directory = corpusDirectory {
                do {
                    let savedCorpus = try Corpus<repeat each Input>.load(from: directory)
                    if config.verbose {
                        print("[Fuzz] Mode: refuzzExtend - loaded \(savedCorpus.count) existing corpus entries as seeds")
                    }
                    // Add existing corpus entries as seeds (avoid keypath due to compiler bug)
                    for entry in savedCorpus.entries {
                        allSeeds.append(entry.input)
                    }
                } catch {
                    if config.verbose {
                        print("[Fuzz] Failed to load corpus for extension: \(error)")
                    }
                }
            }
            return runFuzzing(additionalSeeds: allSeeds, test: test)
        }

        // Handle regressionOnly: only run regression, return empty if no corpus
        if config.corpusMode == .regressionOnly {
            guard corpusExists, let directory = corpusDirectory else {
                if config.verbose {
                    print("[Fuzz] Mode: regressionOnly - no corpus found, nothing to regress")
                }
                return makeEmptyRegressionResult()
            }
            do {
                let savedCorpus = try Corpus<repeat each Input>.load(from: directory)
                return runRegression(corpus: savedCorpus, test: test)
            } catch {
                if config.verbose {
                    print("[Fuzz] Mode: regressionOnly - failed to load corpus: \(error)")
                }
                return makeEmptyRegressionResult()
            }
        }

        // Default (auto): regression if corpus exists
        if corpusExists, let directory = corpusDirectory {
            do {
                let savedCorpus = try Corpus<repeat each Input>.load(from: directory)
                if CorpusSchema.isCompatible(savedCorpus.schemaVersion) {
                    return runRegression(corpus: savedCorpus, test: test)
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

        return runFuzzing(additionalSeeds: additionalSeeds, test: test)
    }

    /// Create an empty result for regression-only mode when no corpus exists.
    private func makeEmptyRegressionResult() -> FuzzResult<repeat each Input> {
        let emptyCorpus = Corpus<repeat each Input>(schemaVersion: CorpusSchema.currentVersion())
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
            corpus: emptyCorpus,
            failures: [],
            stats: emptyStats,
            wasRegression: true,
            coverageChanges: []
        )
    }

    // MARK: - Fuzz Mode

    private func runFuzzing(
        additionalSeeds: [(repeat each Input)] = [],
        test: @escaping ((repeat each Input)) throws -> Void
    ) -> FuzzResult<repeat each Input> {
        @Dependency(\.coverageCounters) var coverageCounters

        let startTime = dateClient.now()
        var corpus = Corpus<repeat each Input>(schemaVersion: CorpusSchema.currentVersion())
        var failures: [(input: (repeat each Input), error: Error)] = []
        var hangs: [(input: (repeat each Input), timeout: TimeInterval)] = []
        var iterationsSinceNewCoverage = 0
        var totalMutations = 0
        var totalGenerations = 0

        // Initialize plateau detector for adaptive early stopping
        var plateauDetector = CoveragePlateauDetector(config: config.plateauConfig)

        // Initialize rare branch tracker for FairFuzz-style targeting
        var rareBranchTracker = config.enableRareBranchTargeting
            ? RareBranchTracker(config: .init(enabled: true))
            : nil

        // Initialize swarm scheduler for mutator subset selection
        var swarmScheduler = config.swarmConfig.enabled
            ? SwarmScheduler(config: config.swarmConfig)
            : nil

        // Initialize adaptive mutation scheduler (MOPT-style)
        var adaptiveMutationScheduler = config.adaptiveMutationConfig.enabled
            ? AdaptiveMutationScheduler(config: config.adaptiveMutationConfig)
            : nil

        // Enable value profile tracking if configured
        if config.enableValueProfile {
            valueProfileTracker.enable()
            valueProfileTracker.clearState()
        }

        // Enable string capture if configured
        if config.enableStringCapture && stringDictionary.isAvailable {
            stringDictionary.clear()
            if config.verbose {
                print("[Fuzz] String capture enabled")
            }
        }

        // Phase 1: Seed with boundary values (defaults + user-provided)
        // Use mutator seeds if provided, otherwise use Fuzzable defaults
        let defaultSeeds = mutatorSeeds?() ?? cartesianProductFuzz()
        let seedInputs = defaultSeeds + additionalSeeds
        for input in seedInputs {
            // Reset coverage and value profile for this test
            // Task-isolated: only affects this task's counters
            coverageCounters.reset()
            if config.enableValueProfile {
                valueProfileTracker.reset()
            }

            // Start string capture for this test
            if config.enableStringCapture && stringDictionary.isAvailable {
                stringDictionary.startCapture()
            }

            // Run test - with optional timeout if configured
            var testError: Error?
            var timedOut = false

            if let perTimeout = config.perInputTimeout {
                // With timeout - use DispatchSemaphore for synchronization
                let semaphore = DispatchSemaphore(value: 0)
                let lock = NSLock()
                nonisolated(unsafe) var capturedError: Error?

                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try test(input)
                    } catch {
                        lock.lock()
                        capturedError = error
                        lock.unlock()
                    }
                    semaphore.signal()
                }

                let waitResult = semaphore.wait(timeout: .now() + perTimeout)
                if waitResult == .timedOut {
                    timedOut = true
                } else {
                    lock.lock()
                    testError = capturedError
                    lock.unlock()
                }
            } else {
                // No timeout - run directly
                do {
                    try test(input)
                } catch {
                    testError = error
                }
            }

            // Stop string capture and accumulate
            if config.enableStringCapture && stringDictionary.isAvailable {
                stringDictionary.stopCapture()
            }

            // Handle test result
            if timedOut {
                let timeout = config.perInputTimeout ?? 0
                hangs.append((input, timeout))
                if config.verbose {
                    print("[Fuzz] Hang detected in seed: input timed out after \(timeout)s")
                }
            } else if let error = testError {
                failures.append((input, error))
            }

            // Process value profile improvements
            let vpImprovements = config.enableValueProfile ? valueProfileTracker.processComparisons() : []

            // Get coverage snapshot (task-isolated, no diff needed)
            if let snapshot = coverageCounters.snapshot() {
                let signature = CoverageSignature(snapshot: snapshot)
                let addedForCoverage = corpus.addIfInteresting(input: repeat each input, signature: signature)

                if addedForCoverage {
                    iterationsSinceNewCoverage = 0
                    if config.verbose {
                        print("[Fuzz] New coverage from seed: \(corpus.count) entries")
                    }
                    // CRITICAL: Even when we found new coverage, check for VP targets to continue the chain.
                    if config.enableValueProfile && !vpImprovements.isEmpty {
                        let newTargets = valueProfileTracker.extractTargets()
                        if !newTargets.isEmpty {
                            priorityMutationIndex = corpus.count - 1
                            savedTargets = newTargets
                            if config.verbose {
                                print("[Fuzz] Coverage + VP chain from seed: \(newTargets.count) target(s)")
                            }
                        }
                    }
                } else if !vpImprovements.isEmpty {
                    // Input made progress on comparisons (new comparison or closer distance)
                    // Always add to corpus to preserve incremental progress
                    corpus.add(input: repeat each input, signature: signature)
                    priorityMutationIndex = corpus.count - 1  // Prioritize this entry next
                    savedTargets = valueProfileTracker.extractTargets()  // Save targets for follow-up
                    iterationsSinceNewCoverage = 0
                    if config.verbose {
                        print("[Fuzz] Value profile progress from seed: \(vpImprovements.count) comparison(s), \(savedTargets.count) target(s)")
                    }
                }
            }
        }

        totalGenerations = seedInputs.count
        // Note: don't clear priorityMutationIndex - seeds may have set a priority to follow up on

        // Phase 2: Coverage-guided fuzzing
        var iteration = seedInputs.count
        var stopReason: FuzzStats.StopReason = .iterationLimit

        while iteration < config.maxIterations {
            // Check stopping conditions
            if dateClient.now().timeIntervalSince(startTime) >= config.maxDuration {
                if config.verbose {
                    print("[Fuzz] Time limit reached after \(iteration) iterations")
                }
                stopReason = .timeLimit
                break
            }

            // Adaptive plateau detection (primary)
            if plateauDetector.hasPlateaued {
                if config.verbose {
                    print("[Fuzz] Coverage plateau detected: \(plateauDetector.summary(includeDetails: true))")
                    print("[Fuzz] Stopping early at iteration \(iteration) (saved \(config.maxIterations - iteration) iterations)")
                }
                stopReason = .coveragePlateau
                break
            }

            // Legacy plateau threshold (fallback when detector disabled)
            if !config.plateauConfig.enabled && iterationsSinceNewCoverage >= config.plateauThreshold {
                if config.verbose {
                    print("[Fuzz] Coverage plateau reached (legacy threshold)")
                }
                stopReason = .legacyPlateau
                break
            }

            // Update swarm configuration if window elapsed
            if let scheduler = swarmScheduler {
                var mutableScheduler = scheduler
                let changed = mutableScheduler.updateConfiguration()
                swarmScheduler = mutableScheduler
                if changed && config.verbose {
                    print("[Fuzz] Swarm: new configuration \(mutableScheduler.summary())")
                }
            }

            // Decide: generate fresh or mutate?
            let input: (repeat each Input)
            let parentIndex: Int?
            var usedStrategy: MutationStrategy?

            if corpus.isEmpty || Double.random(in: 0..<1) < config.generationRatio {
                // Generate fresh input
                // Use mutator seeds if provided, otherwise use Fuzzable defaults
                let fuzzValues = mutatorSeeds?() ?? cartesianProductFuzz()
                guard let fuzzValue = fuzzValues.randomElement() else {
                    continue
                }
                input = fuzzValue
                parentIndex = nil
                totalGenerations += 1
                usedStrategy = .freshGeneration  // Track as fresh generation for adaptive scheduler
            } else {
                // Mutate existing corpus entry
                // Safe: we only enter this branch when !corpus.isEmpty
                // Prioritize entries that made recent value profile progress
                let selectedIndex: Int
                let usingPriority: Bool

                if let priorityIdx = priorityMutationIndex, priorityIdx < corpus.count {
                    selectedIndex = priorityIdx
                    usingPriority = true
                } else if let tracker = rareBranchTracker,
                          config.enableRareBranchTargeting,
                          !tracker.rareIndices.isEmpty {
                    // FairFuzz mode: prefer rare-branch-hitting entries
                    let rareIndices = tracker.rareIndices
                    selectedIndex = corpus.selectForMutation(
                        preferring: rareIndices,
                        probability: config.rareBranchSelectionProbability
                    )!
                    usingPriority = false
                } else {
                    selectedIndex = corpus.selectForMutation()!
                    usingPriority = false
                }
                let parent = corpus.entries[selectedIndex].input
                // Use mutator mutate if provided, otherwise use Fuzzable mutate
                var mutations = mutatorMutate?(parent) ?? mutateInput(parent)

                // Add target-directed mutations from value profile
                var targetMutations: [(repeat each Input)] = []
                if config.enableValueProfile {
                    // Use saved targets for priority entries, otherwise extract from last test
                    let targets = usingPriority && !savedTargets.isEmpty
                        ? savedTargets
                        : valueProfileTracker.extractTargets()
                    targetMutations = generateTargetDirectedMutations(from: parent, targets: targets)
                    mutations.append(contentsOf: targetMutations)
                }

                // When following a priority chain, prefer target-directed mutations
                let mutated: (repeat each Input)
                if usingPriority && !targetMutations.isEmpty {
                    // Try target mutations first when following value profile chain
                    mutated = targetMutations.randomElement()!
                    // Keep priority if we have more targets to try
                    if targetMutations.count <= 1 {
                        priorityMutationIndex = nil
                        savedTargets = []
                    }
                } else {
                    guard let m = mutations.randomElement() else {
                        continue
                    }
                    mutated = m
                    priorityMutationIndex = nil  // Clear priority when not using it
                    savedTargets = []
                }
                input = mutated
                parentIndex = selectedIndex
                totalMutations += 1
            }

            // Reset coverage and value profile for this test
            // Task-isolated: only affects this task's counters
            coverageCounters.reset()
            if config.enableValueProfile {
                valueProfileTracker.reset()
            }

            // Start string capture for this test
            if config.enableStringCapture && stringDictionary.isAvailable {
                stringDictionary.startCapture()
            }

            // Run test - with optional timeout if configured
            var testError: Error?
            var timedOut = false

            if let perTimeout = config.perInputTimeout {
                // With timeout - use DispatchSemaphore for synchronization
                let semaphore = DispatchSemaphore(value: 0)
                let lock = NSLock()
                nonisolated(unsafe) var capturedError: Error?

                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try test(input)
                    } catch {
                        lock.lock()
                        capturedError = error
                        lock.unlock()
                    }
                    semaphore.signal()
                }

                let waitResult = semaphore.wait(timeout: .now() + perTimeout)
                if waitResult == .timedOut {
                    timedOut = true
                } else {
                    lock.lock()
                    testError = capturedError
                    lock.unlock()
                }
            } else {
                // No timeout - run directly
                do {
                    try test(input)
                } catch {
                    testError = error
                }
            }

            // Stop string capture and accumulate
            if config.enableStringCapture && stringDictionary.isAvailable {
                stringDictionary.stopCapture()
            }

            iteration += 1
            iterationsSinceNewCoverage += 1

            // Handle test result
            if timedOut {
                let timeout = config.perInputTimeout ?? 0
                hangs.append((input, timeout))
                if config.verbose {
                    print("[Fuzz] Hang detected: input timed out after \(timeout)s, iteration \(iteration)")
                }
            } else if let error = testError {
                failures.append((input, error))
            }

            // Process value profile improvements
            let vpImprovements = config.enableValueProfile ? valueProfileTracker.processComparisons() : []

            // Get coverage snapshot (task-isolated, no diff needed)
            if let snapshot = coverageCounters.snapshot() {
                let signature = CoverageSignature(snapshot: snapshot)
                let addedForCoverage = corpus.addIfInteresting(input: repeat each input, signature: signature, parentIndex: parentIndex)

                // Record discovery status for plateau detection
                let discoveredNew = addedForCoverage || !vpImprovements.isEmpty
                plateauDetector.record(discoveredNewCoverage: discoveredNew)

                // Record strategy effectiveness for adaptive mutation scheduler
                if let strategy = usedStrategy, var scheduler = adaptiveMutationScheduler {
                    scheduler.recordAttempt(strategy, discoveredNewCoverage: discoveredNew)
                    adaptiveMutationScheduler = scheduler
                }

                // Update rare branch tracker when new entry is added
                if addedForCoverage {
                    rareBranchTracker?.recordEntry(signature)
                    // Periodically recompute threshold (every 50 new entries)
                    if corpus.count % 50 == 0 {
                        rareBranchTracker?.recomputeThreshold()
                    }

                    // Track swarm coverage hit
                    swarmScheduler?.recordCoverageHit()
                }

                if addedForCoverage {
                    iterationsSinceNewCoverage = 0
                    if config.verbose {
                        let rareInfo = rareBranchTracker.map { " (\($0.summary()))" } ?? ""
                        let swarmInfo = swarmScheduler.map { " \($0.summary())" } ?? ""
                        print("[Fuzz] New coverage! \(corpus.count) entries, iteration \(iteration)\(rareInfo)\(swarmInfo)")
                    }
                    // CRITICAL: Even when we found new coverage, check for VP targets to continue the chain.
                    // This handles cases like: a==111 passes (new branch!) revealing b==222 (new comparison).
                    // We need to follow up on b==222 even though we already added for coverage.
                    if config.enableValueProfile && !vpImprovements.isEmpty {
                        let newTargets = valueProfileTracker.extractTargets()
                        if !newTargets.isEmpty {
                            // The corpus entry was just added at addIfInteresting, point to it
                            priorityMutationIndex = corpus.count - 1
                            savedTargets = newTargets
                            if config.verbose {
                                print("[Fuzz] Coverage + VP chain: \(newTargets.count) target(s) to follow")
                            }
                        }
                    }
                } else if !vpImprovements.isEmpty {
                    // Input made progress on comparisons (new comparison or closer distance)
                    // Always add to corpus to preserve incremental progress
                    corpus.add(input: repeat each input, signature: signature, parentIndex: parentIndex)
                    rareBranchTracker?.recordEntry(signature)
                    priorityMutationIndex = corpus.count - 1  // Prioritize this entry next
                    savedTargets = valueProfileTracker.extractTargets()  // Save targets for follow-up
                    iterationsSinceNewCoverage = 0
                    if config.verbose {
                        print("[Fuzz] Value profile progress: \(vpImprovements.count) comparison(s), \(savedTargets.count) target(s), iteration \(iteration)")
                    }
                }
            } else {
                // No coverage counters available - still record for plateau detection
                plateauDetector.record(discoveredNewCoverage: false)
            }
        }

        // Disable value profile tracking
        if config.enableValueProfile {
            valueProfileTracker.disable()
            if config.verbose {
                let (tracked, solved) = valueProfileTracker.stats()
                print("[Fuzz] Value profile: \(tracked) comparisons tracked, \(solved) solved")
            }
        }

        // Report string dictionary stats
        if config.enableStringCapture && stringDictionary.isAvailable && config.verbose {
            print("[Fuzz] String dictionary: \(stringDictionary.count) unique strings captured")
        }

        // Report rare branch stats
        if config.enableRareBranchTargeting, let tracker = rareBranchTracker {
            // Final recomputation for accurate stats
            var finalTracker = tracker
            finalTracker.update(from: corpus.signatures)
            if config.verbose {
                let stats = finalTracker.stats
                print("[Fuzz] Rare branch targeting: \(stats.rareBranches)/\(stats.totalBranches) rare (threshold: \(stats.threshold))")
            }
        }

        // Report swarm testing stats
        if config.swarmConfig.enabled, let scheduler = swarmScheduler {
            if config.verbose {
                print("[Fuzz] \(scheduler.stats.report())")
            }
        }

        // Report adaptive mutation scheduler stats
        if config.adaptiveMutationConfig.enabled, let scheduler = adaptiveMutationScheduler {
            if config.verbose {
                print("[Fuzz] \(scheduler.stats.report())")
            }
        }

        // Phase 3: Minimize corpus
        var finalCorpus = corpus
        if config.minimizeCorpus && corpus.count > 1 {
            finalCorpus = corpus.minimized()
            if config.verbose {
                print("[Fuzz] Minimized corpus: \(corpus.count) -> \(finalCorpus.count)")
            }
        }

        // Phase 4: Save corpus
        if let directory = corpusDirectory {
            do {
                try finalCorpus.save(to: directory)
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

        // Report plateau detector statistics if verbose
        if config.verbose && config.plateauConfig.enabled {
            let pStats = plateauDetector.stats
            print("[Fuzz] Plateau detector: \(pStats.totalDiscoveries) discoveries in \(pStats.totalIterations) iterations")
            print("[Fuzz] Discovery rate: \(String(format: "%.4f", pStats.overallRate)) overall, \(String(format: "%.4f", pStats.windowRate)) recent")
        }

        // Report hang statistics if any were detected
        if !hangs.isEmpty && config.verbose {
            print("[Fuzz] Hang statistics: \(hangs.count) inputs caused timeouts")
        }

        let stats = FuzzStats(
            totalInputs: iteration,
            newPaths: finalCorpus.count,
            mutations: totalMutations,
            generations: totalGenerations,
            duration: duration,
            stopReason: stopReason,
            plateauStats: config.plateauConfig.enabled ? plateauDetector.stats : nil,
            failures: failures.count,
            hangs: hangs.count
        )

        return FuzzResult(
            corpus: finalCorpus,
            failures: failures,
            stats: stats,
            wasRegression: false,
            coverageChanges: []
        )
    }

    // MARK: - Regression Mode

    private func runRegression(
        corpus: Corpus<repeat each Input>,
        test: @escaping ((repeat each Input)) throws -> Void
    ) -> FuzzResult<repeat each Input> {
        @Dependency(\.coverageCounters) var coverageCounters

        let startTime = dateClient.now()
        var failures: [(input: (repeat each Input), error: Error)] = []
        var coverageChanges: [(input: (repeat each Input), expected: CoverageSignature, actual: CoverageSignature)] = []
        var needsRefuzz = false

        if config.verbose {
            print("[Regression] Running \(corpus.count) saved inputs...")
        }

        for entry in corpus.entries {
            // Reset coverage for this test (task-isolated)
            coverageCounters.reset()

            var testError: Error?
            do {
                try test(entry.input)
            } catch {
                testError = error
            }

            if let error = testError {
                failures.append((entry.input, error))
            }

            // Get coverage snapshot (task-isolated, no diff needed)
            if let snapshot = coverageCounters.snapshot() {
                let actualSignature = CoverageSignature(snapshot: snapshot)
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
                try? Corpus<repeat each Input>.delete(from: directory)
            }
            return runFuzzing(test: test)
        }

        let duration = dateClient.now().timeIntervalSince(startTime)
        let stats = FuzzStats(
            totalInputs: corpus.count,
            newPaths: 0,
            mutations: 0,
            generations: 0,
            duration: duration,
            stopReason: .regression,
            plateauStats: nil
        )

        return FuzzResult(
            corpus: corpus,
            failures: failures,
            stats: stats,
            wasRegression: true,
            coverageChanges: coverageChanges
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

        // Strategy 4: Dictionary-based string mutations
        if config.enableStringCapture && stringDictionary.count > 0 {
            results.append(contentsOf: stringDictionaryMutations(input))
        }

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

    /// Mutate using a specific strategy selected by the adaptive mutation scheduler.
    ///
    /// - Parameters:
    ///   - input: The input to mutate.
    ///   - strategy: The strategy to use for mutation.
    /// - Returns: Array of mutated inputs.
    private func mutateWithStrategy(_ input: (repeat each Input), strategy: MutationStrategy) -> [(repeat each Input)] {
        switch strategy {
        case .singleComponent:
            return singleComponentMutations(input)
        case .multiComponent:
            return multiComponentMutations(input)
        case .arithmetic:
            return arithmeticRelationshipMutations(input)
        case .stringDictionary:
            return stringDictionaryMutations(input)
        case .valueProfileDirected:
            // Value profile mutations need targets, so return empty if not available
            return []
        case .customMutator:
            // Use custom mutator if provided
            return mutatorMutate?(input) ?? []
        case .freshGeneration:
            // Generate fresh values
            let fuzzValues = mutatorSeeds?() ?? cartesianProductFuzz()
            return fuzzValues
        }
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

    /// Generate mutations using strings captured from the string dictionary.
    /// This helps crack magic string comparisons by using actual strings seen at runtime.
    private func stringDictionaryMutations(_ input: (repeat each Input)) -> [(repeat each Input)] {
        var results: [(repeat each Input)] = []

        // Find String components and their indices
        var stringComponents: [(index: Int, value: String)] = []
        var componentIdx = 0

        func findStrings<V>(_ value: V) {
            if let strVal = value as? String {
                stringComponents.append((componentIdx, strVal))
            }
            componentIdx += 1
        }
        (repeat findStrings(each input))

        guard !stringComponents.isEmpty else { return [] }

        // Get candidate strings from the dictionary
        let candidates = stringDictionary.mutationCandidates

        // For each String component, try substituting dictionary strings
        for (stringIndex, currentValue) in stringComponents {
            // Try direct substitutions
            for candidate in candidates.prefix(20) { // Limit to avoid explosion
                if candidate != currentValue {
                    if let newTuple = createMutatedTuple(input, mutating: stringIndex, with: candidate) {
                        results.append(newTuple)
                    }
                }
            }

            // Try related strings (similar prefix)
            let related = stringDictionary.relatedStrings(to: currentValue)
            for relatedStr in related.prefix(10) {
                if let newTuple = createMutatedTuple(input, mutating: stringIndex, with: relatedStr) {
                    results.append(newTuple)
                }
            }

            // Try combining current value with dictionary strings
            for candidate in candidates.prefix(5) {
                // Prefix combination
                let prefixed = candidate + currentValue
                if let newTuple = createMutatedTuple(input, mutating: stringIndex, with: prefixed) {
                    results.append(newTuple)
                }

                // Suffix combination
                let suffixed = currentValue + candidate
                if let newTuple = createMutatedTuple(input, mutating: stringIndex, with: suffixed) {
                    results.append(newTuple)
                }
            }
        }

        return results
    }

    /// Generate mutations that target specific comparison values discovered by value profiling.
    ///
    /// This implements multiple strategies:
    /// 1. **Binary search**: Try the target directly and midpoints toward it
    /// 2. **Modulo-aware**: For small targets, try target + k*modulus
    /// 3. **Pair mutations**: For multi-input cases, solve a + b == target
    /// 4. **Array size targeting**: Grow arrays toward size targets
    private func generateTargetDirectedMutations(
        from input: (repeat each Input),
        targets: [ValueProfileTracker.ComparisonTarget]
    ) -> [(repeat each Input)] {
        guard !targets.isEmpty else { return [] }

        var results: [(repeat each Input)] = []

        // Find Int components and their values
        var intComponents: [(index: Int, value: Int)] = []
        // Find array components and their counts
        var arrayComponents: [(index: Int, count: Int, value: Any)] = []
        var componentIdx = 0

        func findComponents<V>(_ value: V) {
            if let intVal = value as? Int {
                intComponents.append((componentIdx, intVal))
            }
            // Check if this is an array (via Collection conformance and count)
            if let collection = value as? any Collection {
                arrayComponents.append((componentIdx, collection.count, value))
            }
            componentIdx += 1
        }
        (repeat findComponents(each input))

        // Strategy 4: Array size targeting
        // When VP detects comparisons like `count >= 100` and we have array inputs,
        // generate arrays with sizes approaching the target.
        if !arrayComponents.isEmpty {
            for target in targets {
                guard let targetSize = Int(exactly: target.target),
                      targetSize > 0,
                      targetSize < 10_000 else { continue }  // Reasonable size bounds

                let currentFromVP = Int(exactly: target.current) ?? 0

                // Find arrays whose count matches the VP's current value
                for (arrayIndex, arrayCount, arrayValue) in arrayComponents {
                    // Only mutate arrays whose size matches the comparison operand
                    guard arrayCount == currentFromVP || arrayCount < targetSize else { continue }

                    // Generate array mutations toward the target size
                    let sizeMutations = generateArraySizeMutations(
                        from: arrayValue,
                        currentSize: arrayCount,
                        targetSize: targetSize,
                        componentIndex: arrayIndex,
                        input: input
                    )
                    results.append(contentsOf: sizeMutations)
                }
            }
        }

        guard !intComponents.isEmpty else { return results }

        // For each target, generate mutations only at positions matching the observed input value.
        // This preserves positions that have already been solved (e.g., if a==111 is solved,
        // don't mutate position 0 when trying to solve b==222).
        for target in targets {
            // Strategy 1: Binary search mutations (try target directly)
            let binaryMutations = target.binarySearchMutations()

            // Strategy 2: Modulo-aware mutations
            let moduloMutations = target.moduloAwareMutations()

            let allSingleMutations = binaryMutations + moduloMutations

            // Only mutate positions where current value matches target.current
            // This ensures we don't clobber already-solved constraints
            let currentInt = Int(exactly: target.current) ?? Int(bitPattern: UInt(truncatingIfNeeded: target.current))
            let candidatePositions = intComponents.filter { $0.value == currentInt }

            // If no exact match, fall back to all positions (for initial exploration)
            let positionsToMutate = candidatePositions.isEmpty ? intComponents : candidatePositions

            for (intIndex, _) in positionsToMutate {
                for mutation in allSingleMutations {
                    if let newTuple = createMutatedTuple(input, mutating: intIndex, with: mutation) {
                        results.append(newTuple)
                    }
                }
            }

            // Strategy 3: Pair mutations for multi-input constraints like a + b == target
            // Mutate BOTH values together to satisfy a + b = target + k*modulus
            if intComponents.count >= 2 {
                guard let targetInt = Int(exactly: target.target) else { continue }

                // Try specific (a, b) pairs that satisfy a + b ≡ target (mod common_moduli)
                let commonModuli = [1000, 100, 256, 1024, 10000]
                let baseValues = [0, 1, 10, 100, 500, 777]  // Common "a" values to try

                for modulus in commonModuli {
                    guard targetInt < modulus else { continue }

                    for k in 0...3 {
                        let targetSum = targetInt + k * modulus

                        for a in baseValues {
                            let b = targetSum - a
                            // Skip if b is negative or too large
                            guard b >= 0 && b < 1_000_000 else { continue }

                            // Create tuple with both values set
                            for i in 0..<intComponents.count {
                                for j in 0..<intComponents.count where i != j {
                                    let (indexI, _) = intComponents[i]
                                    let (indexJ, _) = intComponents[j]

                                    // Set a at indexI, b at indexJ (two-step mutation)
                                    if let intermediate = createMutatedTuple(input, mutating: indexI, with: a),
                                       let finalTuple = createMutatedTuple(intermediate, mutating: indexJ, with: b) {
                                        results.append(finalTuple)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        return results
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

    /// Generate array mutations that grow toward a target size.
    ///
    /// Uses exponential growth (doubling) to quickly approach the target,
    /// plus targeted sizes at key points (target-1, target, target+1).
    private func generateArraySizeMutations(
        from arrayValue: Any,
        currentSize: Int,
        targetSize: Int,
        componentIndex: Int,
        input: (repeat each Input)
    ) -> [(repeat each Input)] {
        var results: [(repeat each Input)] = []

        // Try to cast to a known array type and generate appropriately-sized arrays
        // We handle [Int] specifically since it's the most common case
        if let intArray = arrayValue as? [Int] {
            let sizedArrays = generateSizedIntArrays(
                from: intArray,
                currentSize: currentSize,
                targetSize: targetSize
            )
            for newArray in sizedArrays {
                if let newTuple = createMutatedTuple(input, mutating: componentIndex, with: newArray) {
                    results.append(newTuple)
                }
            }
        } else if let stringArray = arrayValue as? [String] {
            let sizedArrays = generateSizedStringArrays(
                from: stringArray,
                currentSize: currentSize,
                targetSize: targetSize
            )
            for newArray in sizedArrays {
                if let newTuple = createMutatedTuple(input, mutating: componentIndex, with: newArray) {
                    results.append(newTuple)
                }
            }
        } else if let boolArray = arrayValue as? [Bool] {
            let sizedArrays = generateSizedBoolArrays(
                from: boolArray,
                currentSize: currentSize,
                targetSize: targetSize
            )
            for newArray in sizedArrays {
                if let newTuple = createMutatedTuple(input, mutating: componentIndex, with: newArray) {
                    results.append(newTuple)
                }
            }
        }
        // For other array types, fall back to standard mutations

        return results
    }

    /// Generate Int arrays of various sizes approaching the target.
    private func generateSizedIntArrays(
        from array: [Int],
        currentSize: Int,
        targetSize: Int
    ) -> [[Int]] {
        guard currentSize < targetSize else { return [] }

        var results: [[Int]] = []

        // Get a representative element for padding
        let padElement = array.first ?? 0

        // Strategy 1: Direct doubling (exponential growth)
        if currentSize > 0 {
            let doubled = array + array
            if doubled.count <= targetSize + 10 {  // Don't overshoot too much
                results.append(doubled)
            }
        }

        // Strategy 2: Exact target size
        if currentSize < targetSize {
            var exactTarget = array
            while exactTarget.count < targetSize {
                exactTarget.append(padElement)
            }
            results.append(exactTarget)
        }

        // Strategy 3: Target ± small offsets (for off-by-one boundaries)
        for offset in [-1, 1, 2] {
            let size = targetSize + offset
            if size > currentSize && size > 0 {
                var sized = array
                while sized.count < size {
                    sized.append(padElement)
                }
                if sized.count == size {
                    results.append(sized)
                }
            }
        }

        // Strategy 4: Binary search sizes (midpoint between current and target)
        let midpoint = (currentSize + targetSize) / 2
        if midpoint > currentSize && midpoint < targetSize {
            var midArray = array
            while midArray.count < midpoint {
                midArray.append(padElement)
            }
            results.append(midArray)
        }

        return results
    }

    /// Generate String arrays of various sizes approaching the target.
    private func generateSizedStringArrays(
        from array: [String],
        currentSize: Int,
        targetSize: Int
    ) -> [[String]] {
        guard currentSize < targetSize else { return [] }

        var results: [[String]] = []
        let padElement = array.first ?? ""

        // Doubling
        if currentSize > 0 {
            let doubled = array + array
            if doubled.count <= targetSize + 10 {
                results.append(doubled)
            }
        }

        // Exact target
        var exactTarget = array
        while exactTarget.count < targetSize {
            exactTarget.append(padElement)
        }
        results.append(exactTarget)

        return results
    }

    /// Generate Bool arrays of various sizes approaching the target.
    private func generateSizedBoolArrays(
        from array: [Bool],
        currentSize: Int,
        targetSize: Int
    ) -> [[Bool]] {
        guard currentSize < targetSize else { return [] }

        var results: [[Bool]] = []
        let padElement = array.first ?? false

        // Doubling
        if currentSize > 0 {
            let doubled = array + array
            if doubled.count <= targetSize + 10 {
                results.append(doubled)
            }
        }

        // Exact target
        var exactTarget = array
        while exactTarget.count < targetSize {
            exactTarget.append(padElement)
        }
        results.append(exactTarget)

        return results
    }
}
