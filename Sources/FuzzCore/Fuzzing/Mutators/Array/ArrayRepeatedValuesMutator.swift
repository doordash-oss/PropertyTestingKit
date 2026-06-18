// Copyright 2026 DoorDash, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

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
        mutate: { value, rng in
            // Pick one applicable strategy at random, then compute only it. A random
            // index/seed is drawn inside the chosen closure (only one runs).
            var strategies: [(inout FastRNG) -> [Element]] = []

            // Create a version with more copies of a random existing element
            if !value.isEmpty {
                strategies.append { rng in
                    let i = Int.random(in: 0..<value.count, using: &rng)
                    var copy = value
                    copy.append(value[i])
                    copy.append(value[i])
                    return copy
                }

                // Replace other elements with this one
                if value.count >= 3 {
                    strategies.append { rng in
                        let i = Int.random(in: 0..<value.count, using: &rng)
                        var allSame = value
                        for j in allSame.indices.prefix(3) {
                            allSame[j] = value[i]
                        }
                        return allSame
                    }
                }
            }

            // Create an array with a random seed repeated
            if !elementMutator.seeds.prefix(3).isEmpty {
                strategies.append { rng in
                    guard let element = elementMutator.seeds.prefix(3).randomElement(using: &rng) else { return value }
                    var withRepeats = value
                    withRepeats.append(element)
                    withRepeats.append(element)
                    withRepeats.append(element)
                    return withRepeats
                }
            }

            guard let strategy = strategies.randomElement(using: &rng) else { return value }
            return strategy(&rng)
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
