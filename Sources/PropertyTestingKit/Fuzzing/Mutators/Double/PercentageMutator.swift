//
//  PercentageMutator.swift
//  PropertyTestingKit
//

import Dependencies

private let _percentageSeeds: [Double] = [0.0, 0.5, 1.0, -0.1, 1.1, 0.01, 0.99, 0.001, 0.999]

private func _percentageMutate(_ value: Double) -> [Double] {
    var results: [Double] = []
    results.append(min(1.0, value + 0.1))
    results.append(max(0.0, value - 0.1))
    results.append(1.0 - value)
    results.append(value * 0.5)
    return results
}

private func _percentageGenerate(_ rng: inout FastRNG) -> Double {
    Double.random(in: 0.0...1.0, using: &rng)
}

/// Percentage mutator for testing percentage/ratio values (0.0 to 1.0).
public let percentageMutator = Mutator<Double>(
    seeds: _percentageSeeds,
    mutate: _percentageMutate,
    generate: _percentageGenerate
)
