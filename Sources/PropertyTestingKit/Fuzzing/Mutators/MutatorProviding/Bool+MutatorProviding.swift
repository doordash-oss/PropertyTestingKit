//
//  Bool+MutatorProviding.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Dependencies

extension Bool: MutatorProviding {
    public static let defaultMutator: AnyMutator<Bool> = {
        @Dependency(\.random) var random
        let cachedRandom = random  // Cache to avoid repeated TaskLocal lookups
        return AnyMutator(
            seeds: [true, false],
            mutate: { value in [!value] },
            generate: { cachedRandom { rng in Bool.random(using: &rng) } }
        )
    }()
}
