//
//  StringBoundaryMutator.swift
//  PropertyTestingKit
//

import Dependencies

private let _stringBoundarySeeds: [String] = [
    "",
    "a",
    String(repeating: "a", count: 255),
    String(repeating: "a", count: 256),
    String(repeating: "a", count: 65535),
    String(repeating: "🎉", count: 100),
]

private func _stringBoundaryMutate(_ value: String) -> [String] {
    var results: [String] = []
    results.append(value + value)
    results.append(String(repeating: value, count: 10))
    if value.count > 1 {
        let mid = value.index(value.startIndex, offsetBy: value.count / 2)
        results.append(String(value[..<mid]))
    }
    return results
}

private func _stringBoundaryGenerate(_ rng: inout FastRNG) -> String {
    let lengths = [0, 1, 10, 100, 255, 256, 1000]
    let length = lengths.randomElement(using: &rng) ?? 10
    let chars = Array("abcdefghijklmnopqrstuvwxyz")
    return String((0..<length).map { _ in chars.randomElement(using: &rng) ?? "a" })
}

/// String boundary mutator for testing string length boundaries.
public let stringBoundaryMutator = Mutator<String>(
    seeds: _stringBoundarySeeds,
    mutate: _stringBoundaryMutate,
    generate: _stringBoundaryGenerate
)
