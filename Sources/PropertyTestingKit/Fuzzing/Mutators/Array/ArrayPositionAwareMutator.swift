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

//
//  ArrayPositionAwareMutator.swift
//  PropertyTestingKit
//

import Dependencies

/// Creates an array position-aware mutator that inserts elements at specific indices commonly used in tests.
public func arrayPositionAwareMutator<Element: MutatorProviding & Sendable>() -> Mutator<[Element]> {
    let elementMutator = Element.defaultMutator

    var seeds: [[Element]] = []
    // Create arrays with seed values at important positions
    for element in elementMutator.seeds.prefix(5) {
        // Arrays of length 4 with element at index 3
        if let filler = elementMutator.seeds.first, filler as AnyObject !== element as AnyObject {
            var arr = Array(repeating: filler, count: 4)
            arr[3] = element
            seeds.append(arr)
        }

        // Arrays of length 8 with element at index 7
        if let filler = elementMutator.seeds.first {
            var arr = Array(repeating: filler, count: 8)
            arr[7] = element
            seeds.append(arr)
        }
    }

    return Mutator<[Element]>(
        seeds: seeds,
        mutate: { value in
            var results: [[Element]] = []
            let importantIndices = [0, 3, 7, value.count / 2]

            // Insert seed values at important indices
            for element in elementMutator.seeds.prefix(5) {
                for targetIndex in importantIndices where targetIndex <= value.count {
                    var copy = value
                    copy.insert(element, at: targetIndex)
                    results.append(copy)
                }
            }

            // Replace values at important indices with seeds
            for element in elementMutator.seeds.prefix(5) {
                for targetIndex in importantIndices where targetIndex < value.count {
                    var copy = value
                    copy[targetIndex] = element
                    results.append(copy)
                }
            }

            return results
        },
        generate: { rng in
            // Generate arrays with special values at important positions
            let lengths = [4, 8, 10, 16]
            let length = lengths.randomElement(using: &rng) ?? 4
            let importantIndices = [0, 3, 7, length / 2]

            var result = (0..<length).map { _ in elementMutator.generate(&rng) }

            // Place a seed value at an important position
            if let seed = elementMutator.seeds.randomElement(using: &rng),
               let idx = importantIndices.filter({ $0 < length }).randomElement(using: &rng) {
                result[idx] = seed
            }

            return result
        }
    )
}
