//
//  IntMutators.swift
//  PropertyTestingKit
//
//  Built-in integer mutation strategies for fuzz testing.
//

// MARK: - Int Mutator Static Properties

extension AnyMutator where Value == Int {
    public static let boundaries = AnyMutator(IntBoundaryMutator())
    public static let ports = AnyMutator(PortMutator())
    public static let httpStatusCodes = AnyMutator(HTTPStatusCodeMutator())
    public static let negative = AnyMutator(NegativeIntMutator())
    public static let powers = AnyMutator(PowerOfTwoMutator())
}

extension Int {
    /// Create a composed mutator from multiple strategies.
    public static func mutators(_ mutators: AnyMutator<Int>...) -> AnyMutator<Int> {
        AnyMutator(ComposedMutator(mutators))
    }
}
