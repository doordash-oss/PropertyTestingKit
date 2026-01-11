//
//  ArraySequenceInsertionMutator.swift
//  PropertyTestingKit
//

import Dependencies

/// Inserts sequences of seed values into arrays.
struct ArraySequenceInsertionMutator<Element: MutatorProviding & Sendable>: Mutator, Sendable {
    @Dependency(\.random) private var random

    var seeds: [[Element]] {
        var result: [[Element]] = []

        // Create sequences from first few seeds
        let seedElements = Array(Element.defaultMutator.seeds.prefix(5))
        if seedElements.count >= 2 {
            result.append(Array(seedElements.prefix(2)))
        }
        if seedElements.count >= 3 {
            result.append(Array(seedElements.prefix(3)))
            // Also reversed
            result.append(Array(seedElements.prefix(3).reversed()))
        }
        if seedElements.count >= 5 {
            result.append(seedElements)
        }

        return result
    }

    func mutate(_ value: [Element]) -> [[Element]] {
        var results: [[Element]] = []
        let seedElements = Array(Element.defaultMutator.seeds.prefix(5))

        // Insert 2-element sequence
        if seedElements.count >= 2 {
            let seq2 = Array(seedElements.prefix(2))
            results.append(seq2 + value)
            results.append(value + seq2)
        }

        // Insert 3-element sequence
        if seedElements.count >= 3 {
            let seq3 = Array(seedElements.prefix(3))
            results.append(seq3 + value)
            results.append(value + seq3)

            // Insert in middle
            if !value.isEmpty {
                let mid = value.count / 2
                var copy = value
                copy.insert(contentsOf: seq3, at: mid)
                results.append(copy)
            }
        }

        return results
    }

    func generate() -> [Element] {
        random { rng in
            // Generate arrays containing seed sequences
            let elementMutator = Element.defaultMutator
            let seedElements = Array(elementMutator.seeds.prefix(5))

            // Either return a pure seed sequence or generate with some seeds mixed in
            if Bool.random(using: &rng) && !seedElements.isEmpty {
                // Return a seed sequence
                let sequenceLength = Int.random(in: 2...min(5, seedElements.count), using: &rng)
                return Array(seedElements.prefix(sequenceLength))
            } else {
                // Generate array with some seeds
                let length = Int.random(in: 3...8, using: &rng)
                return (0..<length).map { _ in
                    if Bool.random(using: &rng), let seed = seedElements.randomElement(using: &rng) {
                        return seed
                    } else {
                        return elementMutator.generate()
                    }
                }
            }
        }
    }
}
