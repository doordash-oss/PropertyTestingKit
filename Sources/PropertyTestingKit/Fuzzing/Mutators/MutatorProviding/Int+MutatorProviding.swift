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

// Static arrays at file scope to avoid extension static initialization issues
private let _intDivisibilityFactors: [Int] = [7, 11, 13, 77]
private let _intMagicBases: [Int] = [42, 1337, 31337, 0xDEAD, 0xBEEF, 0xCAFE]

private let _intSeeds: [Int] = [
    // Extremes and zero
    0,
    1,
    -1,
    Int.max,
    Int.min,

    // Small values useful for arithmetic relationships
    3,       // Common in b = a*k + 3 patterns
    7,       // Common factor
    10,      // Base 10

    // Common magic numbers (from security/hacking culture)
    42,      // "Answer to everything"
    1337,    // "leet" - extremely common in tests
    31337,   // "elite" - another common magic

    // Common range boundaries
    100,
    200,
    255,     // Max unsigned byte
    256,     // Byte overflow
    1000,
    1024,    // Power of 2

    // Values useful for divisibility tests
    77,      // 7 * 11
    1155,    // 3 * 5 * 7 * 11, in range [1001, 1999]

    // Large values
    1_000_000,
    -1_000_000,
]

private func _intMutate(_ value: Int, _ rng: inout FastRNG) -> Int {
    // Enumerate the candidate neighborhood, then pick ONE: the mutator's job
    // is variety per call, not effort (issue #41).
    // Pre-allocate: up to 7 basic + 8 divisibility = 15 mutations
    var mutations: [Int] = []
    mutations.reserveCapacity(15)

    // Basic arithmetic mutations (with overflow protection)
    if value != Int.max { mutations.append(value + 1) }
    if value != Int.min { mutations.append(value - 1) }
    if value != 0 && value != Int.min { mutations.append(-value) }  // -Int.min overflows
    if value != 0 { mutations.append(value / 2) }
    if value > 0 && value <= Int.max / 2 { mutations.append(value * 2) }
    if value < 0 && value >= Int.min / 2 { mutations.append(value * 2) }

    // Bit manipulation
    if value != 0 { mutations.append(value ^ 1) }  // Flip LSB

    // Divisibility-aware mutations: try nearby multiples of common factors
    for factor in _intDivisibilityFactors {
        let nearestMultiple = (value / factor) * factor
        if nearestMultiple != value && nearestMultiple != 0 {
            mutations.append(nearestMultiple)
        }
        // Also try the next multiple up
        let (next, overflow) = nearestMultiple.addingReportingOverflow(factor)
        if !overflow && next != value {
            mutations.append(next)
        }
    }

    guard !mutations.isEmpty else { return value }
    return mutations[Int.random(in: 0..<mutations.count, using: &rng)]
}

private func _intGenerate(_ rng: inout FastRNG) -> Int {
    // Mix of strategies for interesting random generation
    let strategy = Int.random(in: 0..<10, using: &rng)
    switch strategy {
    case 0:
        // Full range random
        return Int.random(in: Int.min...Int.max, using: &rng)
    case 1:
        // Small positive values (common in tests)
        return Int.random(in: 0...1000, using: &rng)
    case 2:
        // Small negative values
        return Int.random(in: -1000...0, using: &rng)
    case 3:
        // Near zero
        return Int.random(in: -10...10, using: &rng)
    case 4:
        // Powers of 2 (±1)
        let power = Int.random(in: 0..<62, using: &rng)
        let base = 1 << power
        let offset = Int.random(in: -1...1, using: &rng)
        let (result, overflow) = base.addingReportingOverflow(offset)
        return overflow ? base : result
    case 5:
        // Near boundaries
        let boundary = Bool.random(using: &rng) ? Int.max : Int.min
        let offset = Int.random(in: -100...100, using: &rng)
        let (result, overflow) = boundary.addingReportingOverflow(offset)
        return overflow ? boundary : result
    case 6:
        // Byte-aligned values
        return Int.random(in: 0...255, using: &rng) * (Bool.random(using: &rng) ? 1 : -1)
    case 7:
        // Common magic numbers with variations
        let baseIndex = Int.random(in: 0..<_intMagicBases.count, using: &rng)
        let base = _intMagicBases[baseIndex]
        let offset = Int.random(in: -10...10, using: &rng)
        return base + offset
    default:
        // Uniform random in a medium range
        return Int.random(in: -1_000_000...1_000_000, using: &rng)
    }
}

extension Int: MutatorProviding {
    public static let defaultMutator = Mutator<Int>(
        seeds: _intSeeds,
        mutate: _intMutate,
        generate: _intGenerate
    )
}
