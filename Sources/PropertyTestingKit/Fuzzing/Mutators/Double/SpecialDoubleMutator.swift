//
//  SpecialDoubleMutator.swift
//  PropertyTestingKit
//

import Dependencies

struct SpecialDoubleMutator: Mutator, Sendable {
    @Dependency(\.random) private var random

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
        random { rng in seeds.randomElement(using: &rng) } ?? Double.nan
    }
}
