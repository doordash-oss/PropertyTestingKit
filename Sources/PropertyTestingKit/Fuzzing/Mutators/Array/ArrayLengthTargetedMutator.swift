//
//  ArrayLengthTargetedMutator.swift
//  PropertyTestingKit
//

import Dependencies

/// Extends arrays to reach specific target lengths.
struct ArrayLengthTargetedMutator<Element: MutatorProviding & Sendable>: Mutator, Sendable {
    @Dependency(\.random) private var random

    var seeds: [[Element]] {
        var result: [[Element]] = []

        if let first = Element.defaultMutator.seeds.first {
            // Common lengths needed for index-based tests
            for length in [4, 8, 10, 16] {
                result.append(Array(repeating: first, count: length))
            }
        }

        return result
    }

    func mutate(_ value: [Element]) -> [[Element]] {
        var results: [[Element]] = []
        let targetLengths = [4, 8, 10, 16, 32]

        for targetLength in targetLengths where value.count < targetLength {
            // Extend with last element
            if let last = value.last {
                let extension_ = Array(repeating: last, count: targetLength - value.count)
                results.append(value + extension_)
            }

            // Extend with first seed
            if let first = Element.defaultMutator.seeds.first {
                let extension_ = Array(repeating: first, count: targetLength - value.count)
                results.append(value + extension_)
            }
        }

        // Truncate to important lengths
        for targetLength in targetLengths where value.count > targetLength {
            results.append(Array(value.prefix(targetLength)))
        }

        return results
    }

    func generate() -> [Element] {
        random { rng in
            // Generate arrays at target lengths
            let elementMutator = Element.defaultMutator
            let targetLengths = [4, 8, 10, 16, 32]
            let length = targetLengths.randomElement(using: &rng) ?? 8
            return (0..<length).map { _ in elementMutator.generate() }
        }
    }
}
