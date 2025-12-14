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

        /// Enable value profile guidance for comparison tracking.
        /// Requires test code to be compiled with `-sanitize-coverage=trace-cmp`.
        public var enableValueProfile: Bool

        public init(
            maxIterations: Int = 10_000,
            maxDuration: TimeInterval = 60,
            plateauThreshold: Int = 1000,
            generationRatio: Double = 0.3,
            minimizeCorpus: Bool = true,
            verbose: Bool = false,
            enableValueProfile: Bool = true
        ) {
            self.maxIterations = maxIterations
            self.maxDuration = maxDuration
            self.plateauThreshold = plateauThreshold
            self.generationRatio = generationRatio
            self.minimizeCorpus = minimizeCorpus
            self.verbose = verbose
            self.enableValueProfile = enableValueProfile
        }
    }

    private let config: Config
    private let corpusDirectory: URL?
    private let mutatorSeeds: MutatorSeeds?
    private let mutatorMutate: MutatorMutate?

    /// Tracks comparison operand distances for value profile guidance.
    private let valueProfileTracker = ValueProfileTracker()

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

        // Enable value profile tracking if configured
        if config.enableValueProfile {
            valueProfileTracker.enable()
            valueProfileTracker.clearState()
        }

        // Phase 1: Seed with boundary values (defaults + user-provided)
        // Use mutator seeds if provided, otherwise use Fuzzable defaults
        let defaultSeeds = mutatorSeeds?() ?? cartesianProductFuzz()
        let seedInputs = defaultSeeds + additionalSeeds
        for input in seedInputs {
            // Reset value profile for this test
            if config.enableValueProfile {
                valueProfileTracker.reset()
            }

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

            // Process value profile improvements
            let vpImprovements = config.enableValueProfile ? valueProfileTracker.processComparisons() : []

            if let beforeSnapshot = before, let afterSnapshot = coverageCounters.snapshot() {
                let diff = afterSnapshot.difference(from: beforeSnapshot)
                let signature = CoverageSignature(diff: diff)
                let addedForCoverage = corpus.addIfInteresting(input: repeat each input, signature: signature)

                if addedForCoverage {
                    iterationsSinceNewCoverage = 0
                    if config.verbose {
                        print("[Fuzz] New coverage from seed: \(corpus.count) entries")
                    }
                } else if !vpImprovements.isEmpty {
                    // Input made progress on comparisons but didn't find new edges
                    // Add it anyway if it significantly improved comparison distances
                    let bonus = valueProfileTracker.scoreBonus(for: vpImprovements)
                    if bonus >= 5.0 {
                        corpus.add(input: repeat each input, signature: signature)
                        iterationsSinceNewCoverage = 0
                        if config.verbose {
                            print("[Fuzz] Value profile progress from seed (bonus: \(String(format: "%.1f", bonus)))")
                        }
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
                var mutations = mutatorMutate?(parent) ?? mutateInput(parent)

                // Add target-directed mutations from value profile
                if config.enableValueProfile {
                    let targets = valueProfileTracker.extractTargets()
                    let targetMutations = generateTargetDirectedMutations(from: parent, targets: targets)
                    mutations.append(contentsOf: targetMutations)
                }

                guard let mutated = mutations.randomElement() else {
                    continue
                }
                input = mutated
                parentIndex = selectedIndex
                totalMutations += 1
            }

            // Reset value profile for this test
            if config.enableValueProfile {
                valueProfileTracker.reset()
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

            // Process value profile improvements
            let vpImprovements = config.enableValueProfile ? valueProfileTracker.processComparisons() : []

            if let beforeSnapshot = before, let afterSnapshot = coverageCounters.snapshot() {
                let diff = afterSnapshot.difference(from: beforeSnapshot)
                let signature = CoverageSignature(diff: diff)
                let addedForCoverage = corpus.addIfInteresting(input: repeat each input, signature: signature, parentIndex: parentIndex)

                if addedForCoverage {
                    iterationsSinceNewCoverage = 0
                    if config.verbose {
                        print("[Fuzz] New coverage! \(corpus.count) entries, iteration \(iteration)")
                    }
                } else if !vpImprovements.isEmpty {
                    // Input made progress on comparisons but didn't find new edges
                    let bonus = valueProfileTracker.scoreBonus(for: vpImprovements)
                    if bonus >= 5.0 {
                        corpus.add(input: repeat each input, signature: signature, parentIndex: parentIndex)
                        iterationsSinceNewCoverage = 0
                        if config.verbose {
                            print("[Fuzz] Value profile progress (bonus: \(String(format: "%.1f", bonus))), iteration \(iteration)")
                        }
                    }
                }
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

    /// Generate mutations that target specific comparison values discovered by value profiling.
    ///
    /// This implements a binary-search style approach: when we know the code compares
    /// against a specific value (e.g., `x == 12324`), we generate mutations that
    /// include the target directly and binary-search midpoints.
    private func generateTargetDirectedMutations(
        from input: (repeat each Input),
        targets: [ValueProfileTracker.ComparisonTarget]
    ) -> [(repeat each Input)] {
        guard !targets.isEmpty else { return [] }

        var results: [(repeat each Input)] = []

        // Find Int components in the input
        var intIndices: [Int] = []
        var componentIdx = 0

        func findInts<V>(_ value: V) {
            if value is Int {
                intIndices.append(componentIdx)
            }
            componentIdx += 1
        }
        (repeat findInts(each input))

        guard !intIndices.isEmpty else { return [] }

        // For each target, generate mutations at each Int position
        for target in targets {
            let mutations = target.binarySearchMutations()

            for intIndex in intIndices {
                for mutation in mutations {
                    if let newTuple = createMutatedTuple(input, mutating: intIndex, with: mutation) {
                        results.append(newTuple)
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
}
