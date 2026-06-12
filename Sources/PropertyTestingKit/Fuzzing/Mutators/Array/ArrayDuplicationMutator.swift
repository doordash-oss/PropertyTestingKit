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
        mutate: { value, rng in
            var results: [[Element]] = []

            // Duplicate a random element in place
            if !value.isEmpty {
                let i = Int.random(in: 0..<value.count, using: &rng)
                var copy = value
                copy.insert(value[i], at: i)
                results.append(copy)
            }

            // Duplicate entire array
            if !value.isEmpty && value.count < 20 {
                results.append(value + value)
            }

            // Triple a random element
            if !value.isEmpty && value.count < 15 {
                let i = Int.random(in: 0..<value.count, using: &rng)
                var copy = value
                copy.insert(value[i], at: i)
                copy.insert(value[i], at: i)
                results.append(copy)
            }

            guard !results.isEmpty else { return value }
            return results[Int.random(in: 0..<results.count, using: &rng)]
        },
        generate: { rng in
            // Generate arrays with duplicated elements
            let element = elementMutator.generate(&rng)
            let count = Int.random(in: 2...5, using: &rng)
            return Array(repeating: element, count: count)
        }
    )
}
