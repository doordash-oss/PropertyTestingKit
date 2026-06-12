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

extension Array: MutatorProviding where Element: MutatorProviding {
    public static var defaultMutator: Mutator<[Element]> {
        let elementMutator = Element.defaultMutator
        let elementSeeds = Array(elementMutator.seeds.prefix(3))

        var seedsArray: [[Element]] = [[]]
        if !elementSeeds.isEmpty {
            // Single element arrays with first few seeds
            for element in elementSeeds {
                seedsArray.append([element])
            }
            // Small multi-element array from seeds (provides variety)
            if elementSeeds.count >= 3 {
                seedsArray.append(elementSeeds)
            }
        }

        return Mutator<[Element]>(
            seeds: seedsArray,
            mutate: { value, rng in
                // One candidate per variant family; a random index/element/seed
                // stands in for the old per-position enumeration.
                var mutations: [[Element]] = []
                mutations.reserveCapacity(6)

                // === Removal mutation (drop a random element) ===
                if !value.isEmpty {
                    var copy = value
                    copy.remove(at: Int.random(in: 0..<value.count, using: &rng))
                    mutations.append(copy)
                }

                // === Append element (incremental growth) ===
                if !elementSeeds.isEmpty {
                    let element = elementSeeds[Int.random(in: 0..<elementSeeds.count, using: &rng)]
                    mutations.append(value + [element])
                }

                // === Prepend element ===
                if !elementSeeds.isEmpty {
                    let element = elementSeeds[Int.random(in: 0..<Swift.min(2, elementSeeds.count), using: &rng)]
                    mutations.append([element] + value)
                }

                // === Array doubling (exponential growth) ===
                if value.count > 0 {
                    mutations.append(value + value)
                }

                // === Mutate a random element ===
                if !value.isEmpty {
                    let i = Int.random(in: 0..<value.count, using: &rng)
                    var copy = value
                    copy[i] = elementMutator.mutate(value[i], &rng)
                    mutations.append(copy)
                }

                // === Reversal ===
                if value.count > 1 {
                    mutations.append(value.reversed())
                }

                guard !mutations.isEmpty else { return value }
                return mutations[Int.random(in: 0..<mutations.count, using: &rng)]
            },
            generate: { rng in
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
                    elementMutator.generate(&rng)
                }
            }
        )
    }
}
