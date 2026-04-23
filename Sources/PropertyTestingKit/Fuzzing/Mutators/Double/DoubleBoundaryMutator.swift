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
//  DoubleBoundaryMutator.swift
//  PropertyTestingKit
//

import Dependencies

private let _doubleBoundarySeeds: [Double] = [
    0.0, 1.0, -1.0,
    Double.leastNormalMagnitude,
    Double.leastNonzeroMagnitude,
    Double.greatestFiniteMagnitude,
    -Double.greatestFiniteMagnitude,
]

private func _doubleBoundaryMutate(_ value: Double) -> [Double] {
    var results: [Double] = []
    results.append(value + 1)
    results.append(value - 1)
    results.append(value * 2)
    results.append(value / 2)
    results.append(-value)
    results.append(value + 0.1)
    results.append(value - 0.1)
    return results.filter(\.isFinite)
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
