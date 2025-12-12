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
public struct FuzzResult<each Input: Codable & Sendable>: Sendable {
    /// The final corpus after fuzzing/regression.
    public let corpus: Corpus<repeat each Input>

    /// Inputs that caused test failures.
    public let failures: [(input: (repeat each Input), error: Error)]

    /// Statistics about the fuzz run.
    public let stats: FuzzStats

    /// Whether this was a regression run (replaying saved corpus).
    public let wasRegression: Bool

    /// Inputs that had different coverage than expected (regression only).
    public let coverageChanges: [(input: (repeat each Input), expected: CoverageSignature, actual: CoverageSignature)]
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
public final class FuzzEngine<each Input: Fuzzable & Codable & Sendable>: @unchecked Sendable {
    /// Type-erased mutator functions for each input component.
    /// When nil, uses the type's Fuzzable conformance.
    public typealias MutatorSeeds = () -> [(repeat each Input)]
    public typealias MutatorMutate = ((repeat each Input)) -> [(repeat each Input)]
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

        // Extract seeds from mutators
        self.mutatorSeeds = {
            Self.extractMutatorSeeds(mutators: mutators)
        }

        // Extract mutation function from mutators
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
        test: ((repeat each Input)) throws -> Void
    ) -> FuzzResult<repeat each Input> {
        // Check for existing corpus
        if let directory = corpusDirectory, Corpus<repeat each Input>.exists(at: directory) {
            do {
                let savedCorpus = try Corpus<repeat each Input>.load(from: directory)

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
        additionalSeeds: [(repeat each Input)] = [],
        test: ((repeat each Input)) throws -> Void
    ) -> FuzzResult<repeat each Input> {
        @Dependency(\.coverageCounters) var coverageCounters

        let startTime = Date()
        var corpus = Corpus<repeat each Input>(schemaVersion: CorpusSchema.currentVersion())
        var failures: [(input: (repeat each Input), error: Error)] = []
        var iterationsSinceNewCoverage = 0
        var totalMutations = 0
        var totalGenerations = 0

        // Phase 1: Seed with boundary values (defaults + user-provided)
        // Use mutator seeds if provided, otherwise use Fuzzable defaults
        let defaultSeeds = mutatorSeeds?() ?? cartesianProductFuzz()
        let seedInputs = defaultSeeds + additionalSeeds
        for input in seedInputs {
            // Inline coverage testing
            let before = coverageCounters.snapshot()

            var testError: Error?
            do {
                try test(input)
            } catch {
                testError = error
            }

            if let error = testError {
                failures.append((input, error))
            }

            if let beforeSnapshot = before, let afterSnapshot = coverageCounters.snapshot() {
                let diff = afterSnapshot.difference(from: beforeSnapshot)
                let signature = CoverageSignature(diff: diff)
                if corpus.addIfInteresting(input: repeat each input, signature: signature) {
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
            let input: (repeat each Input)
            let parentIndex: Int?

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
            } else {
                // Mutate existing corpus entry
                // Safe: we only enter this branch when !corpus.isEmpty
                let selectedIndex = corpus.selectForMutation()!
                let parent = corpus.entries[selectedIndex].input
                // Use mutator mutate if provided, otherwise use Fuzzable mutate
                let mutations = mutatorMutate?(parent) ?? mutateInput(parent)
                guard let mutated = mutations.randomElement() else {
                    continue
                }
                input = mutated
                parentIndex = selectedIndex
                totalMutations += 1
            }

            // Run test with inline coverage tracking
            let before = coverageCounters.snapshot()

            var testError: Error?
            do {
                try test(input)
            } catch {
                testError = error
            }

            iteration += 1
            iterationsSinceNewCoverage += 1

            if let error = testError {
                failures.append((input, error))
            }

            if let beforeSnapshot = before, let afterSnapshot = coverageCounters.snapshot() {
                let diff = afterSnapshot.difference(from: beforeSnapshot)
                let signature = CoverageSignature(diff: diff)
                if corpus.addIfInteresting(input: repeat each input, signature: signature, parentIndex: parentIndex) {
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
        corpus: Corpus<repeat each Input>,
        test: ((repeat each Input)) throws -> Void
    ) -> FuzzResult<repeat each Input> {
        @Dependency(\.coverageCounters) var coverageCounters

        let startTime = Date()
        var failures: [(input: (repeat each Input), error: Error)] = []
        var coverageChanges: [(input: (repeat each Input), expected: CoverageSignature, actual: CoverageSignature)] = []
        var needsRefuzz = false

        if config.verbose {
            print("[Regression] Running \(corpus.count) saved inputs...")
        }

        for entry in corpus.entries {
            // Inline coverage testing
            let before = coverageCounters.snapshot()

            var testError: Error?
            do {
                try test(entry.input)
            } catch {
                testError = error
            }

            if let error = testError {
                failures.append((entry.input, error))
            }

            if let beforeSnapshot = before, let afterSnapshot = coverageCounters.snapshot() {
                let diff = afterSnapshot.difference(from: beforeSnapshot)
                let actualSignature = CoverageSignature(diff: diff)
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

        // For each component, try mutating it while keeping others the same
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

        return results
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
