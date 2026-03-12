//
//  NegativeIntMutator.swift
//  PropertyTestingKit
//

import Dependencies

private let _negativeIntSeeds: [Int] = [-1, -2, -10, -100, -1000, Int.min, Int.min + 1]

private func _negativeIntMutate(_ value: Int) -> [Int] {
    var results: [Int] = []
    // Use wrapping negation to avoid overflow when value is Int.min
    results.append(0 &- value)
    if value > Int.min { results.append(value - 1) }
    if value < -1 { results.append(value / 2) }
    return results
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
