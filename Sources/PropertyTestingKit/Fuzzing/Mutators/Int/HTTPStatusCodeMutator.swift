//
//  HTTPStatusCodeMutator.swift
//  PropertyTestingKit
//

import Dependencies

struct HTTPStatusCodeMutator: Mutator, Sendable {
    @Dependency(\.fastRNG) private var fastRNG

    var seeds: [Int] {
        [
            100, 101, 200, 201, 204, 301, 302, 304,
            400, 401, 403, 404, 405, 429, 500, 501,
            502, 503, 504, 0, -1, 999, 1000,
        ]
    }

    func mutate(_ value: Int) -> [Int] {
        var results: [Int] = []
        results.append(value + 100)
        results.append(value - 100)
        results.append(value % 600)
        return results.filter { $0 >= 0 }
    }

    func generate() -> Int {
        var rng = fastRNG
        return Int.random(in: 100...599, using: &rng)
    }
}
