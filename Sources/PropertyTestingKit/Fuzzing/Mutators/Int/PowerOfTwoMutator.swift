//
//  PowerOfTwoMutator.swift
//  PropertyTestingKit
//

import Dependencies

struct PowerOfTwoMutator: Mutator, Sendable {
    @Dependency(\.fastRNG) private var fastRNG

    var seeds: [Int] {
        [1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536]
    }

    func mutate(_ value: Int) -> [Int] {
        var results: [Int] = []
        if value > 0 && value < Int.max / 2 { results.append(value * 2) }
        if value > 1 { results.append(value / 2) }
        if value < Int.max { results.append(value + 1) }
        if value > Int.min { results.append(value - 1) }
        return results
    }

    func generate() -> Int {
        var rng = fastRNG
        let power = Int.random(in: 0...16, using: &rng)
        return 1 << power
    }
}
