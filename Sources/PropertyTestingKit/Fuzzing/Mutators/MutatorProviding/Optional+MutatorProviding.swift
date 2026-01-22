//
//  Optional+MutatorProviding.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Dependencies

/// Concrete mutator for Optional values - avoids closure boxing overhead.
public struct OptionalMutator<Wrapped: MutatorProviding>: Mutator, Sendable {
    public let seeds: [Optional<Wrapped>]
    private let wrappedMutator: AnyMutator<Wrapped>
    private let fastRNG: FastRNG

    public init() {
        @Dependency(\.fastRNG) var rng
        self.fastRNG = rng
        self.wrappedMutator = AnyMutator(Wrapped.defaultMutator)
        self.seeds = [nil] + wrappedMutator.seeds.map { .some($0) }
    }

    public func mutate(_ value: Optional<Wrapped>) -> [Optional<Wrapped>] {
        switch value {
        case .none:
            return wrappedMutator.seeds.map { .some($0) }
        case .some(let wrapped):
            return [nil] + wrappedMutator.mutate(wrapped).map { .some($0) }
        }
    }

    public func generate() -> Optional<Wrapped> {
        var rng = fastRNG
        // 20% chance of nil, 80% chance of some value
        if Int.random(in: 0..<5, using: &rng) == 0 {
            return nil
        } else {
            return .some(wrappedMutator.generate())
        }
    }
}

extension Optional: MutatorProviding where Wrapped: MutatorProviding {
    public static var defaultMutator: OptionalMutator<Wrapped> {
        OptionalMutator<Wrapped>()
    }
}
