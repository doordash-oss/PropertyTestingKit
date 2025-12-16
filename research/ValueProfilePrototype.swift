#!/usr/bin/env swift
//
//  ValueProfilePrototype.swift
//  Research prototype for value-profile guided fuzzing
//
//  The idea: track "distance" to goals (like array size >= 100) and
//  prioritize inputs that get closer, even without new code coverage.
//

import Foundation

// MARK: - Fuzzable Protocol (minimal copy for prototype)

protocol Fuzzable {
    static var fuzz: [Self] { get }
    func mutate() -> [Self]
}

extension Int: Fuzzable {
    static var fuzz: [Int] { [0, 1, -1] }

    func mutate() -> [Int] {
        var m: [Int] = []
        if self != Int.max { m.append(self + 1) }
        if self != Int.min { m.append(self - 1) }
        if self != 0 { m.append(-self) }
        return m
    }
}

extension Array: Fuzzable where Element: Fuzzable {
    static var fuzz: [[Element]] {
        let seeds = Array<Element>(Element.fuzz.prefix(3))
        guard !seeds.isEmpty else { return [[]] }

        var result: [[Element]] = [[]]
        for e in seeds { result.append([e]) }
        if seeds.count >= 3 { result.append(seeds) }

        // Cycled arrays with offsets (from our generalized solution)
        for offset in 0..<seeds.count {
            var array: [Element] = []
            for i in 0..<21 {
                array.append(seeds[(i + offset) % seeds.count])
            }
            result.append(array)
        }
        return result
    }

    func mutate() -> [[Element]] {
        var mutations: [[Element]] = []

        // Removal
        for i in indices {
            var copy = self
            copy.remove(at: i)
            mutations.append(copy)
        }

        // Append
        for e in Element.fuzz.prefix(3) {
            mutations.append(self + [e])
        }

        // Doubling (THIS IS THE KEY - no cap for prototype)
        if count > 0 {
            mutations.append(self + self)
        }

        // Mutate positions
        for i in indices {
            for e in Element.fuzz.prefix(2) {
                var copy = self
                copy[i] = e
                mutations.append(copy)
            }
        }

        return mutations
    }
}

// MARK: - Value Profile Tracker

/// Tracks "distance" metrics and prioritizes inputs that improve them
final class ValueProfileTracker {
    struct ScoredInput {
        let input: [Int]
        let distance: Int  // Lower is better (0 = goal reached)
    }

    private var bestDistance: Int = Int.max
    private var bestInputs: [ScoredInput] = []
    private let maxBestInputs = 10

    /// Record a distance measurement. Returns true if this is a new best.
    func record(input: [Int], distance: Int) -> Bool {
        if distance < bestDistance {
            bestDistance = distance
            bestInputs.insert(ScoredInput(input: input, distance: distance), at: 0)
            if bestInputs.count > maxBestInputs {
                bestInputs.removeLast()
            }
            return true
        }
        return false
    }

    /// Get inputs to prioritize for mutation (those closest to goal)
    func prioritizedInputs() -> [[Int]] {
        return bestInputs.map { $0.input }
    }

    var currentBestDistance: Int { bestDistance }
}

// MARK: - Prototype Fuzzer with Value Profile

func fuzzWithValueProfile(
    target: Int,  // Target array size
    maxIterations: Int,
    verbose: Bool = false
) -> (reached: Bool, maxSize: Int, iterations: Int) {
    let tracker = ValueProfileTracker()
    var corpus: [[Int]] = Array<Int>.fuzz
    var maxSizeReached = 0
    var iteration = 0

    // Seed the tracker with initial distances
    for input in corpus {
        let distance = max(0, target - input.count)
        _ = tracker.record(input: input, distance: distance)
        maxSizeReached = max(maxSizeReached, input.count)
    }

    while iteration < maxIterations && maxSizeReached < target {
        iteration += 1

        // KEY DIFFERENCE: Prioritize inputs closest to goal
        let prioritized = tracker.prioritizedInputs()
        let inputPool = prioritized.isEmpty ? corpus : prioritized + corpus.prefix(5)

        // Pick a random input to mutate
        let baseInput = inputPool.randomElement() ?? []

        // Generate mutations
        let mutations = baseInput.mutate()

        for mutant in mutations {
            let distance = max(0, target - mutant.count)
            let isNewBest = tracker.record(input: mutant, distance: distance)

            if mutant.count > maxSizeReached {
                maxSizeReached = mutant.count
                if verbose {
                    print("  Iteration \(iteration): New max size \(maxSizeReached) (distance: \(distance))")
                }

                // Add to corpus if it's progress
                corpus.append(mutant)
            }

            if distance == 0 {
                return (reached: true, maxSize: maxSizeReached, iterations: iteration)
            }
        }
    }

    return (reached: maxSizeReached >= target, maxSize: maxSizeReached, iterations: iteration)
}

// MARK: - Baseline Fuzzer (coverage-only, no value profile)

func fuzzBaseline(
    target: Int,
    maxIterations: Int,
    verbose: Bool = false
) -> (reached: Bool, maxSize: Int, iterations: Int) {
    var corpus: [[Int]] = Array<Int>.fuzz
    var maxSizeReached = corpus.map { $0.count }.max() ?? 0
    var iteration = 0

    while iteration < maxIterations && maxSizeReached < target {
        iteration += 1

        // Random selection from corpus (no prioritization)
        let baseInput = corpus.randomElement() ?? []
        let mutations = baseInput.mutate()

        for mutant in mutations {
            if mutant.count > maxSizeReached {
                maxSizeReached = mutant.count
                if verbose {
                    print("  Iteration \(iteration): New max size \(maxSizeReached)")
                }
                corpus.append(mutant)
            }

            if mutant.count >= target {
                return (reached: true, maxSize: maxSizeReached, iterations: iteration)
            }
        }
    }

    return (reached: maxSizeReached >= target, maxSize: maxSizeReached, iterations: iteration)
}

// MARK: - Capped Mutations (simulating original library behavior)

extension Array where Element: Fuzzable {
    /// Mutations WITH the count < 50 cap (like the real library)
    func mutateCapped() -> [[Element]] {
        var mutations: [[Element]] = []

        // Removal
        for i in indices {
            var copy = self
            copy.remove(at: i)
            mutations.append(copy)
        }

        // Append
        for e in Element.fuzz.prefix(3) {
            mutations.append(self + [e])
        }

        // Doubling WITH CAP (original library behavior)
        if count > 0 && count < 50 {
            mutations.append(self + self)
        }

        // Mutate positions
        for i in indices {
            for e in Element.fuzz.prefix(2) {
                var copy = self
                copy[i] = e
                mutations.append(copy)
            }
        }

        return mutations
    }
}

// MARK: - Capped Baseline (simulates real library limitation)

func fuzzCappedBaseline(
    target: Int,
    maxIterations: Int,
    verbose: Bool = false
) -> (reached: Bool, maxSize: Int, iterations: Int) {
    var corpus: [[Int]] = Array<Int>.fuzz
    var maxSizeReached = corpus.map { $0.count }.max() ?? 0
    var iteration = 0

    while iteration < maxIterations && maxSizeReached < target {
        iteration += 1

        let baseInput = corpus.randomElement() ?? []
        let mutations = baseInput.mutateCapped()  // CAPPED mutations

        for mutant in mutations {
            if mutant.count > maxSizeReached {
                maxSizeReached = mutant.count
                if verbose {
                    print("  Iteration \(iteration): New max size \(maxSizeReached)")
                }
                corpus.append(mutant)
            }

            if mutant.count >= target {
                return (reached: true, maxSize: maxSizeReached, iterations: iteration)
            }
        }
    }

    return (reached: maxSizeReached >= target, maxSize: maxSizeReached, iterations: iteration)
}

// MARK: - Value Profile with Capped Mutations

func fuzzCappedWithValueProfile(
    target: Int,
    maxIterations: Int,
    verbose: Bool = false
) -> (reached: Bool, maxSize: Int, iterations: Int) {
    let tracker = ValueProfileTracker()
    var corpus: [[Int]] = Array<Int>.fuzz
    var maxSizeReached = 0

    // Seed the tracker
    for input in corpus {
        let distance = max(0, target - input.count)
        _ = tracker.record(input: input, distance: distance)
        maxSizeReached = max(maxSizeReached, input.count)
    }

    var iteration = 0
    while iteration < maxIterations && maxSizeReached < target {
        iteration += 1

        // Prioritize inputs closest to goal
        let prioritized = tracker.prioritizedInputs()
        let inputPool = prioritized.isEmpty ? corpus : prioritized + Array(corpus.prefix(5))

        let baseInput = inputPool.randomElement() ?? []
        let mutations = baseInput.mutateCapped()  // CAPPED mutations

        for mutant in mutations {
            let distance = max(0, target - mutant.count)
            _ = tracker.record(input: mutant, distance: distance)

            if mutant.count > maxSizeReached {
                maxSizeReached = mutant.count
                if verbose {
                    print("  Iteration \(iteration): New max size \(maxSizeReached) (distance: \(distance))")
                }
                corpus.append(mutant)
            }

            if distance == 0 {
                return (reached: true, maxSize: maxSizeReached, iterations: iteration)
            }
        }
    }

    return (reached: maxSizeReached >= target, maxSize: maxSizeReached, iterations: iteration)
}

// MARK: - Run Experiments

print("=" * 60)
print("Value Profile Prototype - Array Size Growth")
print("=" * 60)
print()

let targets = [100, 200, 500]
let maxIter = 5000
let runs = 10

print("UNCAPPED DOUBLING (no count < 50 limit)")
print("=" * 60)
for target in targets {
    print("Target: \(target) elements")

    var baselineSuccesses = 0
    var baselineIterations: [Int] = []
    for _ in 0..<runs {
        let result = fuzzBaseline(target: target, maxIterations: maxIter)
        if result.reached {
            baselineSuccesses += 1
            baselineIterations.append(result.iterations)
        }
    }
    let baselineAvg = baselineIterations.isEmpty ? maxIter : baselineIterations.reduce(0, +) / baselineIterations.count
    print("  Baseline:      \(baselineSuccesses)/\(runs) success, avg \(baselineAvg) iterations")

    var vpSuccesses = 0
    var vpIterations: [Int] = []
    for _ in 0..<runs {
        let result = fuzzWithValueProfile(target: target, maxIterations: maxIter)
        if result.reached {
            vpSuccesses += 1
            vpIterations.append(result.iterations)
        }
    }
    let vpAvg = vpIterations.isEmpty ? maxIter : vpIterations.reduce(0, +) / vpIterations.count
    print("  Value Profile: \(vpSuccesses)/\(runs) success, avg \(vpAvg) iterations")
    print()
}

print()
print("CAPPED DOUBLING (count < 50 limit, like real library)")
print("=" * 60)
for target in targets {
    print("Target: \(target) elements")

    var baselineSuccesses = 0
    var baselineIterations: [Int] = []
    var baselineMaxSizes: [Int] = []
    for _ in 0..<runs {
        let result = fuzzCappedBaseline(target: target, maxIterations: maxIter)
        if result.reached {
            baselineSuccesses += 1
            baselineIterations.append(result.iterations)
        }
        baselineMaxSizes.append(result.maxSize)
    }
    let baselineAvg = baselineIterations.isEmpty ? maxIter : baselineIterations.reduce(0, +) / baselineIterations.count
    let baselineMaxAvg = baselineMaxSizes.reduce(0, +) / baselineMaxSizes.count
    print("  Baseline:      \(baselineSuccesses)/\(runs) success, avg \(baselineAvg) iter, avg max size: \(baselineMaxAvg)")

    var vpSuccesses = 0
    var vpIterations: [Int] = []
    var vpMaxSizes: [Int] = []
    for _ in 0..<runs {
        let result = fuzzCappedWithValueProfile(target: target, maxIterations: maxIter)
        if result.reached {
            vpSuccesses += 1
            vpIterations.append(result.iterations)
        }
        vpMaxSizes.append(result.maxSize)
    }
    let vpAvg = vpIterations.isEmpty ? maxIter : vpIterations.reduce(0, +) / vpIterations.count
    let vpMaxAvg = vpMaxSizes.reduce(0, +) / vpMaxSizes.count
    print("  Value Profile: \(vpSuccesses)/\(runs) success, avg \(vpAvg) iter, avg max size: \(vpMaxAvg)")
    print()
}

// Detailed run
print()
print("=" * 60)
print("Detailed Run: Target 100 with CAPPED Value Profile")
print("=" * 60)
let detailed = fuzzCappedWithValueProfile(target: 100, maxIterations: 2000, verbose: true)
print()
print("Result: reached=\(detailed.reached), maxSize=\(detailed.maxSize), iterations=\(detailed.iterations)")

// Helper for string repetition
extension String {
    static func *(lhs: String, rhs: Int) -> String {
        String(repeating: lhs, count: rhs)
    }
}
