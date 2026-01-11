//
//  Bool+MutatorProviding.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Dependencies

extension Bool: MutatorProviding {
    public static var defaultMutator: AnyMutator<Bool> {
        @Dependency(\.random) var random
        return AnyMutator(
            seeds: [true, false],
            mutate: { value in [!value] },
            generate: { random { rng in Bool.random(using: &rng) } }
        )
    }
}
