//
//  DoubleMutators.swift
//  PropertyTestingKit
//
//  Built-in double mutation strategies for fuzz testing.
//

// MARK: - Double Mutator Static Properties

extension Mutator where Value == Double {
    public static let boundaries = doubleBoundaryMutator
    public static let special = specialDoubleMutator
    public static let percentages = percentageMutator
}

extension Double {
    /// Create a composed mutator from multiple strategies.
    public static func mutators(_ mutators: Mutator<Double>...) -> Mutator<Double> {
        Mutator.compose(mutators)
    }
}
