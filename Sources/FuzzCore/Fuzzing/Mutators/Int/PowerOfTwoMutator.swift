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

private let _powerOfTwoSeeds: [Int] = [1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536]

private func _powerOfTwoMutate(_ value: Int, _ rng: inout FastRNG) -> Int {
    // Pick one applicable strategy lazily; preserves uniform distribution over applicable candidates.
    var strategies: [() -> Int] = []
    if value > 0 && value < Int.max / 2 { strategies.append { value * 2 } }
    if value > 1 { strategies.append { value / 2 } }
    if value < Int.max { strategies.append { value + 1 } }
    if value > Int.min { strategies.append { value - 1 } }
    guard let strategy = strategies.randomElement(using: &rng) else { return value }
    return strategy()
}

private func _powerOfTwoGenerate(_ rng: inout FastRNG) -> Int {
    let power = Int.random(in: 0...16, using: &rng)
    return 1 << power
}

/// Power of two mutator for testing power-of-two boundaries.
public let powerOfTwoMutator = Mutator<Int>(
    seeds: _powerOfTwoSeeds,
    mutate: _powerOfTwoMutate,
    generate: _powerOfTwoGenerate
)
