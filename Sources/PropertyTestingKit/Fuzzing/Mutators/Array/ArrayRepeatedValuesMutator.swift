//
//  ArrayRepeatedValuesMutator.swift
//  PropertyTestingKit
//

import Dependencies

/// Creates arrays with many repeated matching values.
struct ArrayRepeatedValuesMutator<Element: MutatorProviding & Sendable>: Mutator, Sendable {
    @Dependency(\.random) private var random

    var seeds: [[Element]] {
        var result: [[Element]] = []

        for element in Element.defaultMutator.seeds.prefix(5) {
            // Arrays with 3+ repeated values (triggers "many-matches")
            result.append(Array(repeating: element, count: 3))
            result.append(Array(repeating: element, count: 4))
            result.append(Array(repeating: element, count: 5))
        }

        // Mixed arrays with some repeated values
        if Element.defaultMutator.seeds.count >= 2 {
            let a = Element.defaultMutator.seeds[0]
            let b = Element.defaultMutator.seeds[1]
            result.append([a, a, a, b])  // 3 of first, 1 of second
            result.append([a, b, a, b, a])  // alternating with majority
        }

        return result
    }

    func mutate(_ value: [Element]) -> [[Element]] {
        var results: [[Element]] = []

        // For each unique element in the array, create version with more of it
        var seen = Set<Int>()
        for i in value.indices {
            let hash = "\(value[i])".hashValue
            if seen.contains(hash) { continue }
            seen.insert(hash)

            // Add 2 more copies of this element
            var copy = value
            copy.append(value[i])
            copy.append(value[i])
            results.append(copy)

            // Replace other elements with this one
            if value.count >= 3 {
                var allSame = value
                for j in allSame.indices.prefix(3) {
                    allSame[j] = value[i]
                }
                results.append(allSame)
            }
        }

        // Create arrays with seeds repeated
        for element in Element.defaultMutator.seeds.prefix(3) {
            var withRepeats = value
            withRepeats.append(element)
            withRepeats.append(element)
            withRepeats.append(element)
            results.append(withRepeats)
        }

        return results
    }

    func generate() -> [Element] {
        random { rng in
            // Generate arrays with repeated values
            let elementMutator = Element.defaultMutator

            let strategy = Int.random(in: 0..<3, using: &rng)
            switch strategy {
            case 0:
                // All same element
                let element = elementMutator.generate()
                let count = Int.random(in: 3...6, using: &rng)
                return Array(repeating: element, count: count)
            case 1:
                // Majority same element
                let main = elementMutator.generate()
                let other = elementMutator.generate()
                return [main, main, main, other]
            default:
                // Alternating with majority
                let a = elementMutator.generate()
                let b = elementMutator.generate()
                return [a, b, a, b, a]
            }
        }
    }
}
