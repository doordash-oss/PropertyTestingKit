//
//  UInt8+MutatorProviding.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Dependencies

extension UInt8: MutatorProviding {
    public static let defaultMutator: AnyMutator<UInt8> = {
        @Dependency(\.random) var random
        let cachedRandom = random  // Cache to avoid repeated TaskLocal lookups
        return AnyMutator(
            seeds: [0, 1, 127, 128, 255, 42, 100],
            mutate: { value in
                var mutations: [UInt8] = []
                if value != UInt8.max { mutations.append(value + 1) }
                if value != 0 { mutations.append(value - 1) }
                if value != 0 { mutations.append(value / 2) }
                if value != 0 && value <= UInt8.max / 2 { mutations.append(value * 2) }
                return mutations
            },
            generate: {
                // Uniform random across full byte range
                cachedRandom { rng in UInt8.random(in: 0...255, using: &rng) }
            }
        )
    }()
}
