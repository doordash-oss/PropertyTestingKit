//
//  BoolMutators.swift
//  PropertyTestingKit
//
//  Built-in boolean mutation strategies for fuzz testing.
//

import Dependencies

// MARK: - Bool Mutator Static Properties

extension Mutator where Value == Bool {
    /// Standard bool mutator (alias for defaultMutator).
    public static var standard: Mutator<Bool> { Bool.defaultMutator }
}

extension Bool {
    /// Create a bool mutator.
    public static func mutator() -> Mutator<Bool> {
        .standard
    }
}
