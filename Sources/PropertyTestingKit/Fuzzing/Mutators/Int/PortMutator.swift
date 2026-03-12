//
//  PortMutator.swift
//  PropertyTestingKit
//

import Dependencies

private let _portSeeds: [Int] = [
    0, 1, 21, 22, 23, 25, 53, 80, 110, 143,
    443, 465, 587, 993, 995, 3306, 5432, 6379,
    8080, 8443, 27017, 65535, 65536, -1,
]

private func _portMutate(_ value: Int) -> [Int] {
    var results: [Int] = []
    if value < 65535 { results.append(value + 1) }
    if value > 0 { results.append(value - 1) }
    results.append(value % 65536)
    if value > 0 && value < 1024 { results.append(value + 1024) }
    return results
}

private func _portGenerate(_ rng: inout FastRNG) -> Int {
    Int.random(in: 0...65535, using: &rng)
}

/// Port number mutator for testing network port handling.
public let portMutator = Mutator<Int>(
    seeds: _portSeeds,
    mutate: _portMutate,
    generate: _portGenerate
)
