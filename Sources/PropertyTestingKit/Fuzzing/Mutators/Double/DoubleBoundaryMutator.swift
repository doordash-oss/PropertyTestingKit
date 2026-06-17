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

private let _doubleBoundarySeeds: [Double] = [
    0.0, 1.0, -1.0,
    Double.leastNormalMagnitude,
    Double.leastNonzeroMagnitude,
    Double.greatestFiniteMagnitude,
    -Double.greatestFiniteMagnitude,
]

private func _doubleBoundaryMutate(_ value: Double, _ rng: inout FastRNG) -> Double {
    // Pick one applicable strategy lazily; preserves uniform distribution over finite candidates.
    let candidates = [value + 1, value - 1, value * 2, value / 2, -value, value + 0.1, value - 0.1]
    let finite = candidates.filter(\.isFinite)
    guard let result = finite.randomElement(using: &rng) else { return value }
    return result
}

private func _doubleBoundaryGenerate(_ rng: inout FastRNG) -> Double {
    _doubleBoundarySeeds.randomElement(using: &rng) ?? 0.0
}

/// Double boundary mutator for testing edge cases.
public let doubleBoundaryMutator = Mutator<Double>(
    seeds: _doubleBoundarySeeds,
    mutate: _doubleBoundaryMutate,
    generate: _doubleBoundaryGenerate
)
