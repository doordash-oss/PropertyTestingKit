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

private let _uintSeeds: [UInt] = [0, 1, UInt.max, UInt.max / 2, 42, 100, 1000]

private func _uintMutate(_ value: UInt, _ rng: inout FastRNG) -> UInt {
    var mutations: [UInt] = []
    if value != UInt.max { mutations.append(value + 1) }
    if value != 0 { mutations.append(value - 1) }
    if value != 0 { mutations.append(value / 2) }
    if value != 0 && value <= UInt.max / 2 { mutations.append(value * 2) }

    guard !mutations.isEmpty else { return value }
    return mutations[Int.random(in: 0..<mutations.count, using: &rng)]
}

private func _uintGenerate(_ rng: inout FastRNG) -> UInt {
    let strategy = Int.random(in: 0..<8, using: &rng)
    switch strategy {
    case 0:
        // Full range
        return UInt.random(in: 0...UInt.max, using: &rng)
    case 1:
        // Small values
        return UInt.random(in: 0...1000, using: &rng)
    case 2:
        // Near zero
        return UInt.random(in: 0...10, using: &rng)
    case 3:
        // Powers of 2
        let power = Int.random(in: 0..<63, using: &rng)
        return UInt(1) << power
    case 4:
        // Near max
        let offset = UInt.random(in: 0...1000, using: &rng)
        return UInt.max - offset
    case 5:
        // Byte values
        return UInt.random(in: 0...255, using: &rng)
    case 6:
        // Common values
        let commons: [UInt] = [0, 1, 42, 100, 255, 256, 1000, 1024, 65535]
        return commons.randomElement(using: &rng) ?? 0
    default:
        // Medium range
        return UInt.random(in: 0...1_000_000, using: &rng)
    }
}

extension UInt: MutatorProviding {
    public static let defaultMutator = Mutator<UInt>(
        seeds: _uintSeeds,
        mutate: _uintMutate,
        generate: _uintGenerate
    )
}
