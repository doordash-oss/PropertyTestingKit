//
//  Bool+MutatorProviding.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Dependencies

/// Concrete mutator for Bool values - avoids closure boxing overhead.
public struct BoolMutator: Mutator, Sendable {
    public let seeds: [Bool] = [true, false]

    private let fastRNG: FastRNG

    public init() {
        @Dependency(\.fastRNG) var rng
        self.fastRNG = rng
    }

    public func mutate(_ value: Bool) -> [Bool] {
        [!value]
    }

    public func generate() -> Bool {
        var rng = fastRNG
        return Bool.random(using: &rng)
    }
}

extension Bool: MutatorProviding {
    public static let defaultMutator = BoolMutator()
}
