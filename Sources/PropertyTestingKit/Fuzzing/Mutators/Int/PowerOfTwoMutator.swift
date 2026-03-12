//
//  PowerOfTwoMutator.swift
//  PropertyTestingKit
//

import Dependencies

private let _powerOfTwoSeeds: [Int] = [1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536]

private func _powerOfTwoMutate(_ value: Int) -> [Int] {
    var results: [Int] = []
    if value > 0 && value < Int.max / 2 { results.append(value * 2) }
    if value > 1 { results.append(value / 2) }
    if value < Int.max { results.append(value + 1) }
    if value > Int.min { results.append(value - 1) }
    return results
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
