//
//  DoubleMutators.swift
//  PropertyTestingKit
//
//  Built-in double mutation strategies for fuzz testing.
//

// MARK: - Double Mutator Static Properties

extension AnyMutator where Value == Double {
    public static let boundaries = AnyMutator(DoubleBoundaryMutator())
    public static let special = AnyMutator(SpecialDoubleMutator())
    public static let percentages = AnyMutator(PercentageMutator())
}

extension Double {
    /// Create a composed mutator from multiple strategies.
    public static func mutators(_ mutators: AnyMutator<Double>...) -> AnyMutator<Double> {
        AnyMutator(ComposedMutator(mutators))
    }
}
