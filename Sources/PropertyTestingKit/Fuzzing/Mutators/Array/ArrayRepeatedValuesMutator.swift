//
//  ArrayRepeatedValuesMutator.swift
//  PropertyTestingKit
//

import Dependencies

/// Creates an array repeated-values mutator that creates arrays with many repeated matching values.
public func arrayRepeatedValuesMutator<Element: MutatorProviding & Sendable>() -> Mutator<[Element]> {
    let elementMutator = Element.defaultMutator

    var seeds: [[Element]] = []
    for element in elementMutator.seeds.prefix(5) {
        // Arrays with 3+ repeated values (triggers "many-matches")
        seeds.append(Array(repeating: element, count: 3))
        seeds.append(Array(repeating: element, count: 4))
        seeds.append(Array(repeating: element, count: 5))
    }

    // Mixed arrays with some repeated values
    if elementMutator.seeds.count >= 2 {
        let a = elementMutator.seeds[0]
        let b = elementMutator.seeds[1]
        seeds.append([a, a, a, b])  // 3 of first, 1 of second
        seeds.append([a, b, a, b, a])  // alternating with majority
    }

    return Mutator<[Element]>(
        seeds: seeds,
        mutate: { value in
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
            for element in elementMutator.seeds.prefix(3) {
                var withRepeats = value
                withRepeats.append(element)
                withRepeats.append(element)
                withRepeats.append(element)
                results.append(withRepeats)
            }

            return results
        },
        generate: { rng in
            // Generate arrays with repeated values
            let strategy = Int.random(in: 0..<3, using: &rng)
            switch strategy {
            case 0:
                // All same element
                let element = elementMutator.generate(&rng)
                let count = Int.random(in: 3...6, using: &rng)
                return Array(repeating: element, count: count)
            case 1:
                // Majority same element
                let main = elementMutator.generate(&rng)
                let other = elementMutator.generate(&rng)
                return [main, main, main, other]
            default:
                // Alternating with majority
                let a = elementMutator.generate(&rng)
                let b = elementMutator.generate(&rng)
                return [a, b, a, b, a]
            }
        }
    )
}
