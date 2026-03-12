//
//  DoubleBoundaryMutator.swift
//  PropertyTestingKit
//

import Dependencies

private let _doubleBoundarySeeds: [Double] = [
    0.0, 1.0, -1.0,
    Double.leastNormalMagnitude,
    Double.leastNonzeroMagnitude,
    Double.greatestFiniteMagnitude,
    -Double.greatestFiniteMagnitude,
]

private func _doubleBoundaryMutate(_ value: Double) -> [Double] {
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

private func _doubleBoundaryGenerate(_ rng: inout FastRNG) -> Double {
    _doubleBoundarySeeds.randomElement(using: &rng) ?? 0.0
}

/// Double boundary mutator for testing edge cases.
public let doubleBoundaryMutator = Mutator<Double>(
    seeds: _doubleBoundarySeeds,
    mutate: _doubleBoundaryMutate,
    generate: _doubleBoundaryGenerate
)
