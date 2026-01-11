//
//  ArrayDuplicationMutator.swift
//  PropertyTestingKit
//

import Dependencies

/// Duplicates elements within arrays to create repeated values.
struct ArrayDuplicationMutator<Element: MutatorProviding & Sendable>: Mutator, Sendable {
    @Dependency(\.random) private var random

    var seeds: [[Element]] {
        // Include arrays with duplicated elements
        var result: [[Element]] = []
        for element in Element.defaultMutator.seeds.prefix(5) {
            result.append([element, element])
            result.append([element, element, element])
            result.append(Array(repeating: element, count: 5))
        }
        return result
    }

    func mutate(_ value: [Element]) -> [[Element]] {
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
    }

    func generate() -> [Element] {
        // Generate arrays with duplicated elements
        let elementMutator = Element.defaultMutator
        let element = elementMutator.generate()
        let count = random { rng in Int.random(in: 2...5, using: &rng) }
        return Array(repeating: element, count: count)
    }
}
