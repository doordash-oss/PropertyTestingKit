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

    /// Extract seeds from mutators using position rotation.
    ///
    /// Instead of computing full cartesian product (O(n1 * n2 * ... * nk)),
    /// we rotate through each position's seeds while using a fixed seed for others.
    /// This ensures every seed is tested at least once with O(n1 + n2 + ... + nk) combinations.
    ///
    /// For example, with seeds [a, b] and [1, 2, 3]:
    /// - Position 0 rotation: (a, 1), (b, 1)  -- all of position 0 with fixed position 1
    /// - Position 1 rotation: (a, 1), (a, 2), (a, 3)  -- fixed position 0 with all of position 1
    /// - Total: 5 combinations instead of 6 (cartesian product)
    ///
    /// The savings grow dramatically with more positions:
    /// - 5 positions with [23, 24, 2, 11, 7] seeds: 67 vs 84,744
    private static func extractMutatorSeeds<each M: Mutator>(
        mutators: (repeat each M)
    ) -> [(repeat each Input)] where (repeat (each M).Value) == (repeat each Input) {
        // Count the number of mutators/positions
        var count = 0
        (repeat { _ = each mutators; count += 1 }())

        // For each position, create a tuple of arrays where:
        // - The expanded position contains all seeds from that mutator
        // - Other positions contain just the first seed (as a fixed reference value)
        let positionsExpanded: [(repeat [each Input])] = (0..<count).map { expandIndex in
            var currentIndex = 0
            return (repeat {
                defer { currentIndex += 1 }
                let seeds = (each mutators).seeds
                if currentIndex == expandIndex {
                    // This position: iterate through all seeds
                    return seeds
                } else {
                    // Other positions: use first seed as fixed value
                    return [seeds[0]]
                }
            }())
        }

        // Use cartesianProduct to expand each position's arrays into full tuples
        return positionsExpanded.flatMap(cartesianProduct)
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

        // Initialize plugin dispatcher with baseline + user plugins
        let dispatcher = PluginDispatcher(plugins: config.allPlugins)

        let allSeeds = additionalSeeds + mutatorSeeds()

        // Early exit if no seeds and no way to generate inputs
        if allSeeds.isEmpty {
            if config.verbose {
                print("[Fuzz] No seeds and no mutations possible - exiting early")
            }
            return .empty
        }

        let stateMachine = FuzzStateMachine(
            seeds: allSeeds,
            pluginDispatcher: dispatcher,
            config: config,
            startTime: startTime,
            randomInputGenerator: mutatorGenerate,
            mutationGenerator: mutatorMutate,
            test: test
        )

        let stateMachineResult = try! await stateMachine.start()

        // Phase 3: Minimize corpus
        var finalCorpus = stateMachineResult.corpus
        let corpusCountBeforeMinimize = await stateMachineResult.corpus.count()
        if config.minimizeCorpus && corpusCountBeforeMinimize > 1 {
            let minimizedSnapshot = await stateMachineResult.corpus.minimized()
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

        let finalSnapshot = await finalCorpus.snapshot()
        return FuzzResult(
            corpus: finalSnapshot,
            failures: stateMachineResult.failures,
            stats: stateMachineResult.stats,
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
            mutations: 0,
            generations: 0,
            duration: duration,
            stopReason: .regression,
        )

        // Dispatch end event to plugins for analysis
        if !config.plugins.isEmpty {
            var dispatcher = PluginDispatcher(plugins: config.plugins)
            let totalCoveredIndices = snapshot.totalCoverage.executedIndices

            if config.verbose {
                print("[Regression] Running analysis: corpus covered \(totalCoveredIndices.count) edges, total edges: \(SanCovCounters.totalEdgeCount)")
            }

            let endContext = PluginEvent<repeat each Input>.EndContext(
                totalCoveredIndices: totalCoveredIndices,
                projectPath: config.projectPath,
                sourceLocation: config.sourceLocation
            )

//            if let actions = try? await dispatcher.dispatch(event: PluginEvent<repeat each Input>.end(endContext)) {
//                _ = executeActions(actions)
//            }
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
