//
//  PercentageMutator.swift
//  PropertyTestingKit
//

import Dependencies

struct PercentageMutator: Mutator, Sendable {
    @Dependency(\.random) private var random

    var seeds: [Double] {
        [0.0, 0.5, 1.0, -0.1, 1.1, 0.01, 0.99, 0.001, 0.999]
    }

    func mutate(_ value: Double) -> [Double] {
        var results: [Double] = []
        results.append(min(1.0, value + 0.1))
        results.append(max(0.0, value - 0.1))
        results.append(1.0 - value)
        results.append(value * 0.5)
        return results
    }

    func generate() -> Double {
        random { rng in Double.random(in: 0.0...1.0, using: &rng) }
    }
}
