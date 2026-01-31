//
//  SpecialDoubleMutator.swift
//  PropertyTestingKit
//

import Dependencies

struct SpecialDoubleMutator: Mutator, Sendable {
    @Dependency(\.fastRNG) private var fastRNG

    var seeds: [Double] {
        [
            Double.nan,
            Double.infinity,
            -Double.infinity,
            Double.pi,
            Double.ulpOfOne,
            0.1 + 0.2, // classic floating point issue
        ]
    }

    func mutate(_ value: Double) -> [Double] {
        var results: [Double] = []
        if value.isFinite {
            results.append(value.nextUp)
            results.append(value.nextDown)
        }
        results.append(Double.nan)
        results.append(Double.infinity)
        return results
    }

    func generate() -> Double {
        var rng = fastRNG
        return seeds.randomElement(using: &rng) ?? Double.nan
    }
}
