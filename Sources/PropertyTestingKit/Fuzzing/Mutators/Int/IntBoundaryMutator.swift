//
//  IntBoundaryMutator.swift
//  PropertyTestingKit
//

import Dependencies

private let _intBoundarySeeds: [Int] = [
    0, 1, -1,
    Int.max, Int.min,
    Int(Int8.max), Int(Int8.min),
    Int(Int16.max), Int(Int16.min),
    Int(Int32.max), Int(Int32.min),
    Int(UInt8.max), Int(UInt16.max),
]

private func _intBoundaryMutate(_ value: Int) -> [Int] {
    var results: [Int] = []
    if value < Int.max { results.append(value + 1) }
    if value > Int.min { results.append(value - 1) }
    if value != 0 && value > Int.min / 2 && value < Int.max / 2 {
        results.append(value * 2)
    }
    if value != 0 { results.append(value / 2) }
    // Use wrapping negation to avoid overflow when value is Int.min
    results.append(0 &- value)
    return results
}

private func _intBoundaryGenerate(_ rng: inout FastRNG) -> Int {
    _intBoundarySeeds.randomElement(using: &rng) ?? 0
}

/// Integer boundary mutator for testing edge cases.
public let intBoundaryMutator = Mutator<Int>(
    seeds: _intBoundarySeeds,
    mutate: _intBoundaryMutate,
    generate: _intBoundaryGenerate
)
