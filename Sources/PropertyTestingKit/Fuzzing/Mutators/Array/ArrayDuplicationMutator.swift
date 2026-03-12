//
//  ArrayDuplicationMutator.swift
//  PropertyTestingKit
//

import Dependencies

/// Creates an array duplication mutator that duplicates elements within arrays.
public func arrayDuplicationMutator<Element: MutatorProviding & Sendable>() -> Mutator<[Element]> {
    let elementMutator = Element.defaultMutator

    // Include arrays with duplicated elements
    var seeds: [[Element]] = []
    for element in elementMutator.seeds.prefix(5) {
        seeds.append([element, element])
        seeds.append([element, element, element])
        seeds.append(Array(repeating: element, count: 5))
    }

    return Mutator<[Element]>(
        seeds: seeds,
        mutate: { value in
            var results: [[Element]] = []

            // Duplicate each element in place
            for i in value.indices {
                var copy = value
                copy.insert(value[i], at: i)
                results.append(copy)
            }

            // Duplicate entire array
            if !value.isEmpty && value.count < 20 {
                results.append(value + value)
            }

            // Triple an element
            for i in value.indices where value.count < 15 {
                var copy = value
                copy.insert(value[i], at: i)
                copy.insert(value[i], at: i)
                results.append(copy)
            }

            return results
        },
        generate: { rng in
            // Generate arrays with duplicated elements
            let element = elementMutator.generate(&rng)
            let count = Int.random(in: 2...5, using: &rng)
            return Array(repeating: element, count: count)
        }
    )
}
