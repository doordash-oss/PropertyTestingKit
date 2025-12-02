//
//  FuzzEngine.swift
//  PropertyTestingKit
//
//  Coverage-guided fuzzing engine that combines mutation and generation.
//

import Dependencies
import Foundation

// MARK: - FuzzResult

/// The result of a fuzz test run.
public struct FuzzResult<Input: Codable & Sendable>: Sendable {
    /// The final corpus after fuzzing/regression.
    public let corpus: Corpus<Input>

    /// Inputs that caused test failures.
    public let failures: [(input: Input, error: Error)]

    /// Statistics about the fuzz run.
    public let stats: FuzzStats

    /// Whether this was a regression run (replaying saved corpus).
    public let wasRegression: Bool

    /// Inputs that had different coverage than expected (regression only).
    public let coverageChanges: [(input: Input, expected: CoverageSignature, actual: CoverageSignature)]
}

/// Statistics about a fuzz run.
public struct FuzzStats: Sendable {
    /// Total inputs tested.
    public let totalInputs: Int

    /// New coverage paths discovered.
    public let newPaths: Int

    /// Number of mutations performed.
    public let mutations: Int

    /// Number of fresh generations.
    public let generations: Int

    /// Time spent fuzzing.
    public let duration: TimeInterval

    /// Inputs per second.
    public var inputsPerSecond: Double {
        duration > 0 ? Double(totalInputs) / duration : 0
    }
}

// MARK: - FuzzEngine

/// A coverage-guided fuzzing engine.
///
/// The engine runs in two modes:
/// 1. **Fuzz mode**: Generate inputs, track coverage, build corpus
/// 2. **Regression mode**: Replay saved corpus, verify coverage unchanged
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
public final class FuzzEngine<Input: Fuzzable & Codable & Sendable>: @unchecked Sendable {
    /// Configuration for the fuzzing run.
    public struct Config: Sendable {
        /// Maximum iterations (inputs to test).
        public var maxIterations: Int

        /// Maximum time to spend fuzzing.
        public var maxDuration: TimeInterval

        /// Stop after this many iterations without new coverage.
        public var plateauThreshold: Int

        /// Probability of generating fresh vs mutating (0.0-1.0).
        /// Higher = more fresh generation.
        public var generationRatio: Double

        /// Whether to minimize the corpus before saving.
        public var minimizeCorpus: Bool

        /// Verbose logging.
        public var verbose: Bool

        public init(
            maxIterations: Int = 10_000,
            maxDuration: TimeInterval = 60,
            plateauThreshold: Int = 1000,
            generationRatio: Double = 0.3,
            minimizeCorpus: Bool = true,
            verbose: Bool = false
        ) {
            self.maxIterations = maxIterations
            self.maxDuration = maxDuration
            self.plateauThreshold = plateauThreshold
            self.generationRatio = generationRatio
            self.minimizeCorpus = minimizeCorpus
            self.verbose = verbose
        }
    }

    private let config: Config
    private let corpusDirectory: URL?

    public init(config: Config = Config(), corpusDirectory: URL? = nil) {
        self.config = config
        self.corpusDirectory = corpusDirectory
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
        test: (Input) throws -> Void
    ) -> FuzzResult<Input> {
        // Check for existing corpus
        if let directory = corpusDirectory, Corpus<Input>.exists(at: directory) {
            do {
                let savedCorpus = try Corpus<Input>.load(from: directory)

                // Check schema compatibility
                if CorpusSchema.isCompatible(savedCorpus.schemaVersion) {
                    // Run regression mode
                    return runRegression(corpus: savedCorpus, test: test)
                } else {
                    // Schema changed, need to re-fuzz
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

        // Run fuzz mode
        return runFuzzing(additionalSeeds: additionalSeeds, test: test)
    }

    // MARK: - Fuzz Mode

    private func runFuzzing(
        additionalSeeds: [Input] = [],
        test: (Input) throws -> Void
    ) -> FuzzResult<Input> {
        let startTime = Date()
        var corpus = Corpus<Input>(schemaVersion: CorpusSchema.currentVersion())
        var failures: [(input: Input, error: Error)] = []
        var iterationsSinceNewCoverage = 0
        var totalMutations = 0
        var totalGenerations = 0

        // Phase 1: Seed with boundary values (defaults + user-provided)
        let seedInputs = Input.fuzz + additionalSeeds
        for input in seedInputs {
            let result = testWithCoverage(input: input, test: test)

            if let error = result.error {
                failures.append((input, error))
            }

            if let signature = result.signature {
                if corpus.addIfInteresting(input: input, signature: signature) {
                    iterationsSinceNewCoverage = 0
                    if config.verbose {
                        print("[Fuzz] New coverage from seed: \(corpus.count) entries")
                    }
                }
            }
        }

        totalGenerations = seedInputs.count

        // Phase 2: Coverage-guided fuzzing
        var iteration = seedInputs.count
        while iteration < config.maxIterations {
            // Check stopping conditions
            if Date().timeIntervalSince(startTime) >= config.maxDuration {
                if config.verbose {
                    print("[Fuzz] Time limit reached")
                }
                break
            }

            if iterationsSinceNewCoverage >= config.plateauThreshold {
                if config.verbose {
                    print("[Fuzz] Coverage plateau reached")
                }
                break
            }

            // Decide: generate fresh or mutate?
            let input: Input
            let parentIndex: Int?

            if corpus.isEmpty || Double.random(in: 0..<1) < config.generationRatio {
                // Generate fresh input
                guard let fuzzValue = Input.fuzz.randomElement() else {
                    continue
                }
                input = fuzzValue
                parentIndex = nil
                totalGenerations += 1
            } else {
                // Mutate existing corpus entry
                // Safe: we only enter this branch when !corpus.isEmpty
                let selectedIndex = corpus.selectForMutation()!
                let parent = corpus.entries[selectedIndex].input
                guard let mutated = parent.input.mutate().randomElement() else {
                    continue
                }
                input = mutated
                parentIndex = selectedIndex
                totalMutations += 1
            }

            // Run test
            let result = testWithCoverage(input: input, test: test)
            iteration += 1
            iterationsSinceNewCoverage += 1

            if let error = result.error {
                failures.append((input, error))
            }

            if let signature = result.signature {
                if corpus.addIfInteresting(input: input, signature: signature, parentIndex: parentIndex) {
                    iterationsSinceNewCoverage = 0
                    if config.verbose {
                        print("[Fuzz] New coverage! \(corpus.count) entries, iteration \(iteration)")
                    }
                }
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

        let duration = Date().timeIntervalSince(startTime)
        let stats = FuzzStats(
            totalInputs: iteration,
            newPaths: finalCorpus.count,
            mutations: totalMutations,
            generations: totalGenerations,
            duration: duration
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
        corpus: Corpus<Input>,
        test: (Input) throws -> Void
    ) -> FuzzResult<Input> {
        let startTime = Date()
        var failures: [(input: Input, error: Error)] = []
        var coverageChanges: [(input: Input, expected: CoverageSignature, actual: CoverageSignature)] = []
        var needsRefuzz = false

        if config.verbose {
            print("[Regression] Running \(corpus.count) saved inputs...")
        }

        for entry in corpus.entries {
            let result = testWithCoverage(input: entry.input.input, test: test)

            if let error = result.error {
                failures.append((entry.input.input, error))
            }

            if let actualSignature = result.signature {
                if actualSignature != entry.signature {
                    coverageChanges.append((
                        input: entry.input.input,
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
                try? Corpus<Input>.delete(from: directory)
            }
            return runFuzzing(test: test)
        }

        let duration = Date().timeIntervalSince(startTime)
        let stats = FuzzStats(
            totalInputs: corpus.count,
            newPaths: 0,
            mutations: 0,
            generations: 0,
            duration: duration
        )

        return FuzzResult(
            corpus: corpus,
            failures: failures,
            stats: stats,
            wasRegression: true,
            coverageChanges: coverageChanges
        )
    }

    // MARK: - Test Execution

    private struct TestResult {
        let signature: CoverageSignature?
        let error: Error?
    }

    private func testWithCoverage(
        input: Input,
        test: (Input) throws -> Void
    ) -> TestResult {
        @Dependency(\.coverageCounters) var coverageCounters

        guard let before = coverageCounters.snapshot() else {
            // Coverage not available, run test without tracking
            do {
                try test(input)
                return TestResult(signature: nil, error: nil)
            } catch {
                return TestResult(signature: nil, error: error)
            }
        }

        var testError: Error?
        do {
            try test(input)
        } catch {
            testError = error
        }

        guard let after = coverageCounters.snapshot() else {
            return TestResult(signature: nil, error: testError)
        }

        let diff = after.difference(from: before)
        let signature = CoverageSignature(diff: diff)

        return TestResult(signature: signature, error: testError)
    }
}
