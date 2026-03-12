//
//  SpecialDoubleMutator.swift
//  PropertyTestingKit
//

import Dependencies

private let _specialDoubleSeeds: [Double] = [
    Double.nan,
    Double.infinity,
    -Double.infinity,
    Double.pi,
    Double.ulpOfOne,
    0.1 + 0.2, // classic floating point issue
]

private func _specialDoubleMutate(_ value: Double) -> [Double] {
    var results: [Double] = []
    if value.isFinite {
        results.append(value.nextUp)
        results.append(value.nextDown)
    }
    results.append(Double.nan)
    results.append(Double.infinity)
    return results
}

private func _specialDoubleGenerate(_ rng: inout FastRNG) -> Double {
    _specialDoubleSeeds.randomElement(using: &rng) ?? Double.nan
}

/// Special double mutator for testing special floating point values.
public let specialDoubleMutator = Mutator<Double>(
    seeds: _specialDoubleSeeds,
    mutate: _specialDoubleMutate,
    generate: _specialDoubleGenerate
)
