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

/// Creates an array sequence-insertion mutator that inserts sequences of seed values into arrays.
public func arraySequenceInsertionMutator<Element: MutatorProviding & Sendable>() -> Mutator<[Element]> {
    let elementMutator = Element.defaultMutator

    var seeds: [[Element]] = []
    // Create sequences from first few seeds
    let seedElements = Array(elementMutator.seeds.prefix(5))
    if seedElements.count >= 2 {
        seeds.append(Array(seedElements.prefix(2)))
    }
    if seedElements.count >= 3 {
        seeds.append(Array(seedElements.prefix(3)))
        // Also reversed
        seeds.append(Array(seedElements.prefix(3).reversed()))
    }
    if seedElements.count >= 5 {
        seeds.append(seedElements)
    }

    return Mutator<[Element]>(
        seeds: seeds,
        mutate: { value, rng in
            var results: [[Element]] = []
            let seedElements = Array(elementMutator.seeds.prefix(5))

            // Insert 2-element sequence
            if seedElements.count >= 2 {
                let seq2 = Array(seedElements.prefix(2))
                results.append(seq2 + value)
                results.append(value + seq2)
            }

            // Insert 3-element sequence
            if seedElements.count >= 3 {
                let seq3 = Array(seedElements.prefix(3))
                results.append(seq3 + value)
                results.append(value + seq3)

                // Insert in middle
                if !value.isEmpty {
                    let mid = value.count / 2
                    var copy = value
                    copy.insert(contentsOf: seq3, at: mid)
                    results.append(copy)
                }
            }

            guard !results.isEmpty else { return value }
            return results[Int.random(in: 0..<results.count, using: &rng)]
        },
        generate: { rng in
            // Generate arrays containing seed sequences
            let seedElements = Array(elementMutator.seeds.prefix(5))

            // Either return a pure seed sequence or generate with some seeds mixed in
            if Bool.random(using: &rng) && !seedElements.isEmpty {
                // Return a seed sequence
                let sequenceLength = Int.random(in: 2...min(5, seedElements.count), using: &rng)
                return Array(seedElements.prefix(sequenceLength))
            } else {
                // Generate array with some seeds
                let length = Int.random(in: 3...8, using: &rng)
                return (0..<length).map { _ in
                    if Bool.random(using: &rng), let seed = seedElements.randomElement(using: &rng) {
                        return seed
                    } else {
                        return elementMutator.generate(&rng)
                    }
                }
            }
        }
    )
}
