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
//  ArrayLengthTargetedMutator.swift
//  PropertyTestingKit
//

import Dependencies

/// Creates an array length-targeted mutator that extends arrays to specific target lengths.
public func arrayLengthTargetedMutator<Element: MutatorProviding & Sendable>() -> Mutator<[Element]> {
    let elementMutator = Element.defaultMutator

    var seeds: [[Element]] = []
    if let first = elementMutator.seeds.first {
        // Common lengths needed for index-based tests
        for length in [4, 8, 10, 16] {
            seeds.append(Array(repeating: first, count: length))
        }
    }

    return Mutator<[Element]>(
        seeds: seeds,
        mutate: { value in
            var results: [[Element]] = []
            let targetLengths = [4, 8, 10, 16, 32]

            for targetLength in targetLengths where value.count < targetLength {
                // Extend with last element
                if let last = value.last {
                    let extension_ = Array(repeating: last, count: targetLength - value.count)
                    results.append(value + extension_)
                }

                // Extend with first seed
                if let first = elementMutator.seeds.first {
                    let extension_ = Array(repeating: first, count: targetLength - value.count)
                    results.append(value + extension_)
                }
            }

            // Truncate to important lengths
            for targetLength in targetLengths where value.count > targetLength {
                results.append(Array(value.prefix(targetLength)))
            }

            return results
        },
        generate: { rng in
            // Generate arrays at target lengths
            let targetLengths = [4, 8, 10, 16, 32]
            let length = targetLengths.randomElement(using: &rng) ?? 8
            return (0..<length).map { _ in elementMutator.generate(&rng) }
        }
    )
}
