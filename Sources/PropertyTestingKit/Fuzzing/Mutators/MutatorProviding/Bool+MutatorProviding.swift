//
//  Bool+MutatorProviding.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Dependencies

private let _boolSeeds: [Bool] = [true, false]

private func _boolMutate(_ value: Bool) -> [Bool] {
    [!value]
}

private func _boolGenerate(_ rng: inout FastRNG) -> Bool {
    Bool.random(using: &rng)
}

extension Bool: MutatorProviding {
    public static let defaultMutator = Mutator<Bool>(
        seeds: _boolSeeds,
        mutate: _boolMutate,
        generate: _boolGenerate
    )
}
