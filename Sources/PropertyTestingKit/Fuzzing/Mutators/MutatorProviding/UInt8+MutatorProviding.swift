//
//  UInt8+MutatorProviding.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Dependencies

private let _uint8Seeds: [UInt8] = [0, 1, 127, 128, 255, 42, 100]

private func _uint8Mutate(_ value: UInt8) -> [UInt8] {
    var mutations: [UInt8] = []
    if value != UInt8.max { mutations.append(value + 1) }
    if value != 0 { mutations.append(value - 1) }
    if value != 0 { mutations.append(value / 2) }
    if value != 0 && value <= UInt8.max / 2 { mutations.append(value * 2) }
    return mutations
}

private func _uint8Generate(_ rng: inout FastRNG) -> UInt8 {
    // Uniform random across full byte range
    UInt8.random(in: 0...255, using: &rng)
}

extension UInt8: MutatorProviding {
    public static let defaultMutator = Mutator<UInt8>(
        seeds: _uint8Seeds,
        mutate: _uint8Mutate,
        generate: _uint8Generate
    )
}
