//
//  BoolMutators.swift
//  PropertyTestingKit
//
//  Built-in boolean mutation strategies for fuzz testing.
//

import Dependencies

// MARK: - Bool Mutator Static Properties

extension AnyMutator where Value == Bool {
    public static let standard = AnyMutator(BoolMutator())
}

extension Bool {
    /// Create a bool mutator.
    public static func mutator() -> AnyMutator<Bool> {
        .standard
    }
}

// MARK: - Bool Mutator Implementation

struct BoolMutator: Mutator, Sendable {
    @Dependency(\.random) private var random

    var seeds: [Bool] { [true, false] }

    func mutate(_ value: Bool) -> [Bool] { [!value] }

    func generate() -> Bool {
        random { rng in Bool.random(using: &rng) }
    }
}
