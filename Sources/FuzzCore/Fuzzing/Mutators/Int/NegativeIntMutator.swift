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

private let _negativeIntSeeds: [Int] = [-1, -2, -10, -100, -1000, Int.min, Int.min + 1]

private func _negativeIntMutate(_ value: Int, _ rng: inout FastRNG) -> Int {
    // Pick one applicable strategy lazily; preserves uniform distribution over applicable candidates.
    var strategies: [() -> Int] = []
    // Use wrapping negation to avoid overflow when value is Int.min
    strategies.append { 0 &- value }
    if value > Int.min { strategies.append { value - 1 } }
    if value < -1 { strategies.append { value / 2 } }
    guard let strategy = strategies.randomElement(using: &rng) else { return value }
    return strategy()
}

private func _negativeIntGenerate(_ rng: inout FastRNG) -> Int {
    -Int.random(in: 1...Int.max, using: &rng)
}

/// Negative integer mutator for testing negative value handling.
public let negativeIntMutator = Mutator<Int>(
    seeds: _negativeIntSeeds,
    mutate: _negativeIntMutate,
    generate: _negativeIntGenerate
)
