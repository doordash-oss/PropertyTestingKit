//
//  NegativeIntMutator.swift
//  PropertyTestingKit
//

import Dependencies

struct NegativeIntMutator: Mutator, Sendable {
    @Dependency(\.fastRNG) private var fastRNG

    var seeds: [Int] {
        [-1, -2, -10, -100, -1000, Int.min, Int.min + 1]
    }

    func mutate(_ value: Int) -> [Int] {
        var results: [Int] = []
        // Use wrapping negation to avoid overflow when value is Int.min
        results.append(0 &- value)
        if value > Int.min { results.append(value - 1) }
        if value < -1 { results.append(value / 2) }
        return results
    }

    func generate() -> Int {
        var rng = fastRNG
        return -Int.random(in: 1...Int.max, using: &rng)
    }
}
