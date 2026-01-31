//
//  DoubleBoundaryMutator.swift
//  PropertyTestingKit
//

import Dependencies

struct DoubleBoundaryMutator: Mutator, Sendable {
    @Dependency(\.fastRNG) private var fastRNG

    var seeds: [Double] {
        [
            0.0, 1.0, -1.0,
            Double.leastNormalMagnitude,
            Double.leastNonzeroMagnitude,
            Double.greatestFiniteMagnitude,
            -Double.greatestFiniteMagnitude,
        ]
    }

    func mutate(_ value: Double) -> [Double] {
        var results: [Double] = []
        results.append(value + 1)
        results.append(value - 1)
        results.append(value * 2)
        results.append(value / 2)
        results.append(-value)
        results.append(value + 0.1)
        results.append(value - 0.1)
        return results.filter(\.isFinite)
    }

    func generate() -> Double {
        var rng = fastRNG
        return seeds.randomElement(using: &rng) ?? 0.0
    }
}
