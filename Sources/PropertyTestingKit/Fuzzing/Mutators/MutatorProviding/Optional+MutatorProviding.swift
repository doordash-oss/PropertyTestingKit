//
//  Optional+MutatorProviding.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Dependencies

extension Optional: MutatorProviding where Wrapped: MutatorProviding {
    public static var defaultMutator: AnyMutator<Optional<Wrapped>> {
        @Dependency(\.fastRNG) var _fastRNG
        let fastRNG = _fastRNG
        let wrappedMutator = Wrapped.defaultMutator
        let seeds: [Optional<Wrapped>] = [nil] + wrappedMutator.seeds.map { .some($0) }

        return AnyMutator(
            seeds: seeds,
            mutate: { value in
                switch value {
                case .none:
                    return wrappedMutator.seeds.map { .some($0) }
                case .some(let wrapped):
                    return [nil] + wrappedMutator.mutate(wrapped).map { .some($0) }
                }
            },
            generate: {
                var rng = fastRNG
                // 20% chance of nil, 80% chance of some value
                if Int.random(in: 0..<5, using: &rng) == 0 {
                    return nil
                } else {
                    return .some(wrappedMutator.generate())
                }
            }
        )
    }
}
