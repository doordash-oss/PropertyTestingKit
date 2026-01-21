//
//  ArrayPositionAwareMutator.swift
//  PropertyTestingKit
//

import Dependencies

/// Inserts elements at specific indices commonly used in tests.
struct ArrayPositionAwareMutator<Element: MutatorProviding & Sendable>: Mutator, Sendable {
    @Dependency(\.fastRNG) private var fastRNG

    var seeds: [[Element]] {
        var result: [[Element]] = []

        // Create arrays with seed values at important positions
        for element in Element.defaultMutator.seeds.prefix(5) {
            // Arrays of length 4 with element at index 3
            if let filler = Element.defaultMutator.seeds.first, filler as AnyObject !== element as AnyObject {
                var arr = Array(repeating: filler, count: 4)
                arr[3] = element
                result.append(arr)
            }

            // Arrays of length 8 with element at index 7
            if let filler = Element.defaultMutator.seeds.first {
                var arr = Array(repeating: filler, count: 8)
                arr[7] = element
                result.append(arr)
            }
        }

        return result
    }

    func mutate(_ value: [Element]) -> [[Element]] {
        var results: [[Element]] = []
        let importantIndices = [0, 3, 7, value.count / 2]

        // Insert seed values at important indices
        for element in Element.defaultMutator.seeds.prefix(5) {
            for targetIndex in importantIndices where targetIndex <= value.count {
                var copy = value
                copy.insert(element, at: targetIndex)
                results.append(copy)
            }
        }

        // Replace values at important indices with seeds
        for element in Element.defaultMutator.seeds.prefix(5) {
            for targetIndex in importantIndices where targetIndex < value.count {
                var copy = value
                copy[targetIndex] = element
                results.append(copy)
            }
        }

        return results
    }

    func generate() -> [Element] {
        var rng = fastRNG
        // Generate arrays with special values at important positions
        let elementMutator = Element.defaultMutator
        let lengths = [4, 8, 10, 16]
        let length = lengths.randomElement(using: &rng) ?? 4
        let importantIndices = [0, 3, 7, length / 2]

        var result = (0..<length).map { _ in elementMutator.generate() }

        // Place a seed value at an important position
        if let seed = elementMutator.seeds.randomElement(using: &rng),
           let idx = importantIndices.filter({ $0 < length }).randomElement(using: &rng) {
            result[idx] = seed
        }

        return result
    }
}
