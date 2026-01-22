//
//  UInt+MutatorProviding.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Dependencies

/// Concrete mutator for UInt values - avoids closure boxing overhead.
public struct UIntMutator: Mutator, Sendable {
    public let seeds: [UInt] = [0, 1, UInt.max, UInt.max / 2, 42, 100, 1000]

    private let fastRNG: FastRNG

    public init() {
        @Dependency(\.fastRNG) var rng
        self.fastRNG = rng
    }

    public func mutate(_ value: UInt) -> [UInt] {
        var mutations: [UInt] = []
        if value != UInt.max { mutations.append(value + 1) }
        if value != 0 { mutations.append(value - 1) }
        if value != 0 { mutations.append(value / 2) }
        if value != 0 && value <= UInt.max / 2 { mutations.append(value * 2) }
        return mutations
    }

    public func generate() -> UInt {
        var rng = fastRNG
        let strategy = Int.random(in: 0..<8, using: &rng)
        switch strategy {
        case 0:
            // Full range
            return UInt.random(in: 0...UInt.max, using: &rng)
        case 1:
            // Small values
            return UInt.random(in: 0...1000, using: &rng)
        case 2:
            // Near zero
            return UInt.random(in: 0...10, using: &rng)
        case 3:
            // Powers of 2
            let power = Int.random(in: 0..<63, using: &rng)
            return UInt(1) << power
        case 4:
            // Near max
            let offset = UInt.random(in: 0...1000, using: &rng)
            return UInt.max - offset
        case 5:
            // Byte values
            return UInt.random(in: 0...255, using: &rng)
        case 6:
            // Common values
            let commons: [UInt] = [0, 1, 42, 100, 255, 256, 1000, 1024, 65535]
            return commons.randomElement(using: &rng) ?? 0
        default:
            // Medium range
            return UInt.random(in: 0...1_000_000, using: &rng)
        }
    }
}

extension UInt: MutatorProviding {
    public static let defaultMutator = UIntMutator()
}
