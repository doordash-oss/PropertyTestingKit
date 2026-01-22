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

// MARK: - MutatorOps (Closure holder - single reference capture)

/// Holds pre-computed closures for mutation operations.
/// Closures are created once at init, and callers capture this single class reference
/// instead of the mutator tuple directly. This reduces per-call ARC overhead.
final class MutatorOps<each Input: Sendable>: @unchecked Sendable {
    let seeds: [(repeat each Input)]
    let generateFn: @Sendable () -> (repeat each Input)
    let mutateFn: @Sendable ((repeat each Input)) -> [(repeat each Input)]

    init<each M: Mutator>(
        mutators: (repeat each M),
        inputSize: Int
    ) where (repeat (each M).Value) == (repeat each Input) {
        self.seeds = Self.extractSeeds(mutators: mutators, inputSize: inputSize)

        // Store closures that capture mutators.
        // These are stored once; calling code captures this class reference (1 retain)
        // rather than capturing the mutator tuple directly (N retains).
        self.generateFn = {
            (repeat (each mutators).generate())
        }
        self.mutateFn = { input in
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

    private static func extractSeeds<each M: Mutator>(
        mutators: (repeat each M),
        inputSize: Int
    ) -> [(repeat each Input)] where (repeat (each M).Value) == (repeat each Input) {
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
}

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
public actor FuzzEngine<each M: Mutator> where repeat (each M).Value: Codable & Sendable {
    @Dependency(\.dateClient) private var dateClient
    @Dependency(\.random) private var random
    @Dependency(\.corpusPersistence) private var corpusPersistenceClient
    @Dependency(\.coverageCounters) private var coverageCounters
    @Dependency(\.corpusRegistry) private var corpusRegistry

    // Type alias for the combined input tuple
    public typealias Input = (repeat (each M).Value)

    // MARK: - Properties
    private let config: FuzzEngineConfig
    private let corpusDirectory: URL?
    // Store mutator operations in a class - single reference capture reduces ARC
    private let ops: MutatorOps<repeat (each M).Value>

    /// Initialize with mutators.
    ///
    /// - Parameters:
    ///   - mutators: A tuple of mutators, one for each input type.
    ///   - config: Fuzzing configuration.
    ///   - corpusDirectory: Where to save/load the corpus.
    public init(
        mutators: (repeat each M),
        config: FuzzEngineConfig = FuzzEngineConfig(),
        corpusDirectory: URL? = nil
    ) {
        let inputSize = Self.inputCount(for: repeat (each M).self)
        self.config = config
        self.corpusDirectory = corpusDirectory
        // Create ops class - callers capture single class reference instead of mutator tuple
        self.ops = MutatorOps(mutators: mutators, inputSize: inputSize)
    }

    // MARK: - Helpers

    /// Count the number of elements in a parameter pack.
    private static func inputCount(for mutator: repeat (each M).Type) -> Int {
        var count = 0
        (repeat { _ = each mutator; count += 1 }())
        return count
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
        additionalSeeds: [Input] = [],
        test: @escaping @Sendable (Input) async throws -> Void
    ) async -> FuzzResult<repeat (each M).Value> {
        return await runWithMode(additionalSeeds: additionalSeeds, test: test)
    }

    /// Internal dispatch based on corpus mode.
    private func runWithMode(
        additionalSeeds: [Input],
        test: @escaping @Sendable (Input) async throws -> Void
    ) async -> FuzzResult<repeat (each M).Value> {
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
                    let savedSnapshot: CorpusSnapshot<repeat (each M).Value> = try corpusPersistenceClient.loadSnapshot(from: directory)
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
                let savedSnapshot: CorpusSnapshot<repeat (each M).Value> = try corpusPersistenceClient.loadSnapshot(from: directory)
                return await runRegression(snapshot: savedSnapshot, test: test)
            } catch {
                if config.verbose {
                    print("[Fuzz] Mode: regressionOnly - failed to load corpus: \(error)")
                }
                return .empty
            }
        }

        // Default (auto): regression if corpus exists
        // We don't check schema version - runRegression will detect if coverage
        // changed and trigger re-fuzzing automatically.
        if corpusExists, let directory = corpusDirectory {
            do {
                let savedSnapshot: CorpusSnapshot<repeat (each M).Value> = try corpusPersistenceClient.loadSnapshot(from: directory)
                return await runRegression(snapshot: savedSnapshot, test: test)
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
        additionalSeeds: [Input] = [],
        test: @escaping @Sendable (Input) async throws -> Void
    ) async -> FuzzResult<repeat (each M).Value> {
        let startTime = dateClient.now()

        let allSeeds = additionalSeeds + ops.seeds

        // Early exit if no seeds and no way to generate inputs
        if allSeeds.isEmpty {
            if config.verbose {
                print("[Fuzz] No seeds and no mutations possible - exiting early")
            }
            return .empty
        }

        // Capture ops (single class reference) - reduces ARC overhead vs capturing mutator tuple
        let ops = self.ops
        let generateFn: FuzzStateMachine<repeat (each M).Value>.MutatorGenerate = {
            ops.generateFn()
        }
        let mutateFn: FuzzStateMachine<repeat (each M).Value>.MutatorMutate = { input in
            ops.mutateFn(input)
        }

        let stateMachine = FuzzStateMachine<repeat (each M).Value>(
            seeds: allSeeds,
            plugins: config.allPlugins,
            config: config,
            startTime: startTime,
            randomInputGenerator: generateFn,
            mutationGenerator: mutateFn,
            test: test
        )

        let stateMachineResult = try! await stateMachine.start()

        // Phase 3: Minimize corpus
        var finalCorpus = stateMachineResult.corpus
        let corpusCountBeforeMinimize = await stateMachineResult.corpus.count()
        if config.minimizeCorpus && corpusCountBeforeMinimize > 1 {
            let minimizedSnapshot = await stateMachineResult.corpus.minimized()
            finalCorpus = CorpusClient<repeat (each M).Value>.live(corpus: Corpus(from: minimizedSnapshot))
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
        snapshot: CorpusSnapshot<repeat (each M).Value>,
        test: @escaping @Sendable (Input) async throws -> Void
    ) async -> FuzzResult<repeat (each M).Value> {
        let startTime = dateClient.now()
        var failures: [(input: Input, error: Error)] = []
        var coverageChanges: [(input: Input, expected: CoverageSignature, actual: CoverageSignature)] = []
        var needsRefuzz = false

        if config.verbose {
            print("[Regression] Running \(snapshot.count) saved inputs...")
        }

        // Hoist measurement context creation outside the loop for performance.
        // This avoids hash table insert/remove operations per entry.
        let context = coverageCounters.beginMeasurement()
        defer { coverageCounters.endMeasurement(context) }

        for entry in snapshot.entries {
            // Reset coverage for this entry (cheap memset instead of hash table ops)
            coverageCounters.resetCoverage(context)

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
