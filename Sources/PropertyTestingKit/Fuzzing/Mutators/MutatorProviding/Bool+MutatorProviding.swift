//
//  Bool+MutatorProviding.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Dependencies

extension Bool: MutatorProviding {
    public static let defaultMutator: AnyMutator<Bool> = {
        @Dependency(\.fastRNG) var _fastRNG
        let fastRNG = _fastRNG
        return AnyMutator(
            seeds: [true, false],
            mutate: { value in [!value] },
            generate: {
                var rng = fastRNG
                return Bool.random(using: &rng)
            }
        )
    }()
}
