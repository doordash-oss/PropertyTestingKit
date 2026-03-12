//
//  IntMutators.swift
//  PropertyTestingKit
//
//  Built-in integer mutation strategies for fuzz testing.
//

// MARK: - Int Mutator Static Properties

extension Mutator where Value == Int {
    public static let boundaries = intBoundaryMutator
    public static let ports = portMutator
    public static let httpStatusCodes = httpStatusCodeMutator
    public static let negative = negativeIntMutator
    public static let powers = powerOfTwoMutator
}

extension Int {
    /// Create a composed mutator from multiple strategies.
    public static func mutators(_ mutators: Mutator<Int>...) -> Mutator<Int> {
        Mutator.compose(mutators)
    }
}
