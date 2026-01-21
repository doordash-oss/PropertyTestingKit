//
//  Array+MutatorProviding.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Dependencies

extension Array: MutatorProviding where Element: MutatorProviding {
    public static var defaultMutator: AnyMutator<[Element]> {
        @Dependency(\.fastRNG) var _fastRNG
        let fastRNG = _fastRNG
        let elementSeeds = Array(Element.defaultMutator.seeds.prefix(3))

        var seeds: [[Element]] = [[]]
        if !elementSeeds.isEmpty {
            // Single element arrays with first few seeds
            for element in elementSeeds {
                seeds.append([element])
            }
            // Small multi-element array from seeds (provides variety)
            if elementSeeds.count >= 3 {
                seeds.append(elementSeeds)
            }
        }

        return AnyMutator(
            seeds: seeds,
            mutate: { value in
                var mutations: [[Element]] = []
                let elementMutator = Element.defaultMutator

                // === Removal mutations ===
                for i in value.indices {
                    var copy = value
                    copy.remove(at: i)
                    mutations.append(copy)
                }

                // === Append elements (incremental growth) ===
                for element in elementMutator.seeds.prefix(3) {
                    mutations.append(value + [element])
                }

                // === Prepend element ===
                for element in elementMutator.seeds.prefix(2) {
                    mutations.append([element] + value)
                }

                // === Array doubling (exponential growth) ===
                if value.count > 0 {
                    mutations.append(value + value)
                }

                // === Mutate individual elements ===
                for i in value.indices {
                    for mutated in elementMutator.mutate(value[i]).prefix(2) {
                        var copy = value
                        copy[i] = mutated
                        mutations.append(copy)
                    }
                }

                // === Reversal ===
                if value.count > 1 {
                    mutations.append(value.reversed())
                }

                return mutations
            },
            generate: {
                var rng = fastRNG
                let elementMutator = Element.defaultMutator

                // Decide length with bias toward smaller arrays
                let strategy = Int.random(in: 0..<10, using: &rng)
                let length: Int
                switch strategy {
                case 0:
                    // Empty
                    length = 0
                case 1, 2:
                    // Single element
                    length = 1
                case 3, 4, 5:
                    // Small (2-5)
                    length = Int.random(in: 2...5, using: &rng)
                case 6, 7:
                    // Medium (6-15)
                    length = Int.random(in: 6...15, using: &rng)
                case 8:
                    // Large (16-50)
                    length = Int.random(in: 16...50, using: &rng)
                default:
                    // Very large (50-100)
                    length = Int.random(in: 50...100, using: &rng)
                }

                // Generate elements
                return (0..<length).map { _ in
                    elementMutator.generate()
                }
            }
        )
    }
}
