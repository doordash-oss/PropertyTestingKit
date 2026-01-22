//
//  UInt8+MutatorProviding.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Dependencies

/// Concrete mutator for UInt8 values - avoids closure boxing overhead.
public struct UInt8Mutator: Mutator, Sendable {
    public let seeds: [UInt8] = [0, 1, 127, 128, 255, 42, 100]

    private let fastRNG: FastRNG

    public init() {
        @Dependency(\.fastRNG) var rng
        self.fastRNG = rng
    }

    public func mutate(_ value: UInt8) -> [UInt8] {
        var mutations: [UInt8] = []
        if value != UInt8.max { mutations.append(value + 1) }
        if value != 0 { mutations.append(value - 1) }
        if value != 0 { mutations.append(value / 2) }
        if value != 0 && value <= UInt8.max / 2 { mutations.append(value * 2) }
        return mutations
    }

    public func generate() -> UInt8 {
        // Uniform random across full byte range
        var rng = fastRNG
        return UInt8.random(in: 0...255, using: &rng)
    }
}

extension UInt8: MutatorProviding {
    public static let defaultMutator = UInt8Mutator()
}
