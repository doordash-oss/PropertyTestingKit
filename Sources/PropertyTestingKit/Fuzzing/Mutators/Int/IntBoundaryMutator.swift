//
//  IntBoundaryMutator.swift
//  PropertyTestingKit
//

import Dependencies

struct IntBoundaryMutator: Mutator, Sendable {
    @Dependency(\.fastRNG) private var fastRNG

    var seeds: [Int] {
        [
            0, 1, -1,
            Int.max, Int.min,
            Int(Int8.max), Int(Int8.min),
            Int(Int16.max), Int(Int16.min),
            Int(Int32.max), Int(Int32.min),
            Int(UInt8.max), Int(UInt16.max),
        ]
    }

    func mutate(_ value: Int) -> [Int] {
        var results: [Int] = []
        if value < Int.max { results.append(value + 1) }
        if value > Int.min { results.append(value - 1) }
        if value != 0 && value > Int.min / 2 && value < Int.max / 2 {
            results.append(value * 2)
        }
        if value != 0 { results.append(value / 2) }
        // Use wrapping negation to avoid overflow when value is Int.min
        results.append(0 &- value)
        return results
    }

    func generate() -> Int {
        var rng = fastRNG
        return seeds.randomElement(using: &rng) ?? 0
    }
}
