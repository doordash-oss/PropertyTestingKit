//
//  EmptyStringMutator.swift
//  PropertyTestingKit
//

import Dependencies

private let _emptyStringSeeds: [String] = ["", " ", "\t", "\n", "\0"]

private func _emptyStringMutate(_ value: String) -> [String] {
    var results: [String] = []
    if !value.isEmpty {
        results.append("")
        if let first = value.first {
            results.append(String(first))
        }
        if let last = value.last {
            results.append(String(last))
        }
    }
    results.append(value + value)
    return results
}

private func _emptyStringGenerate(_ rng: inout FastRNG) -> String {
    _emptyStringSeeds.randomElement(using: &rng) ?? ""
}

/// Empty string mutator for testing empty/whitespace string handling.
public let emptyStringMutator = Mutator<String>(
    seeds: _emptyStringSeeds,
    mutate: _emptyStringMutate,
    generate: _emptyStringGenerate
)
