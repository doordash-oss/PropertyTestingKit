//
//  HTTPStatusCodeMutator.swift
//  PropertyTestingKit
//

import Dependencies

private let _httpStatusCodeSeeds: [Int] = [
    100, 101, 200, 201, 204, 301, 302, 304,
    400, 401, 403, 404, 405, 429, 500, 501,
    502, 503, 504, 0, -1, 999, 1000,
]

private func _httpStatusCodeMutate(_ value: Int) -> [Int] {
    var results: [Int] = []
    results.append(value + 100)
    results.append(value - 100)
    results.append(value % 600)
    return results.filter { $0 >= 0 }
}

private func _httpStatusCodeGenerate(_ rng: inout FastRNG) -> Int {
    Int.random(in: 100...599, using: &rng)
}

/// HTTP status code mutator for testing HTTP response handling.
public let httpStatusCodeMutator = Mutator<Int>(
    seeds: _httpStatusCodeSeeds,
    mutate: _httpStatusCodeMutate,
    generate: _httpStatusCodeGenerate
)
