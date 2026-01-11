//
//  EmptyStringMutator.swift
//  PropertyTestingKit
//

import Dependencies

struct EmptyStringMutator: Mutator, Sendable {
    @Dependency(\.random) private var random

    var seeds: [String] {
        ["", " ", "\t", "\n", "\0"]
    }

    func mutate(_ value: String) -> [String] {
        var results: [String] = []
        if !value.isEmpty {
            results.append("")
            results.append(String(value.first!))
            results.append(String(value.last!))
        }
        results.append(value + value)
        return results
    }

    func generate() -> String {
        random { rng in seeds.randomElement(using: &rng) } ?? ""
    }
}
