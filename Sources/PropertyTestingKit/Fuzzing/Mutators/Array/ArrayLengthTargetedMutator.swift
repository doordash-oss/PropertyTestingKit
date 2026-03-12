//
//  ArrayLengthTargetedMutator.swift
//  PropertyTestingKit
//

import Dependencies

/// Creates an array length-targeted mutator that extends arrays to specific target lengths.
public func arrayLengthTargetedMutator<Element: MutatorProviding & Sendable>() -> Mutator<[Element]> {
    let elementMutator = Element.defaultMutator

    var seeds: [[Element]] = []
    if let first = elementMutator.seeds.first {
        // Common lengths needed for index-based tests
        for length in [4, 8, 10, 16] {
            seeds.append(Array(repeating: first, count: length))
        }
    }

    return Mutator<[Element]>(
        seeds: seeds,
        mutate: { value in
            var results: [[Element]] = []
            let targetLengths = [4, 8, 10, 16, 32]

            for targetLength in targetLengths where value.count < targetLength {
                // Extend with last element
                if let last = value.last {
                    let extension_ = Array(repeating: last, count: targetLength - value.count)
                    results.append(value + extension_)
                }

                // Extend with first seed
                if let first = elementMutator.seeds.first {
                    let extension_ = Array(repeating: first, count: targetLength - value.count)
                    results.append(value + extension_)
                }
            }

            // Truncate to important lengths
            for targetLength in targetLengths where value.count > targetLength {
                results.append(Array(value.prefix(targetLength)))
            }

            return results
        },
        generate: { rng in
            // Generate arrays at target lengths
            let targetLengths = [4, 8, 10, 16, 32]
            let length = targetLengths.randomElement(using: &rng) ?? 8
            return (0..<length).map { _ in elementMutator.generate(&rng) }
        }
    )
}
