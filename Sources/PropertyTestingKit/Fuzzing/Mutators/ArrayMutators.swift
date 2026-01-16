//
//  ArrayMutators.swift
//  PropertyTestingKit
//
//  Built-in array mutation strategies for fuzz testing.
//

// MARK: - Array Mutator Static Properties

extension AnyMutator {
    public static func duplication<Element: MutatorProviding & Sendable>() -> AnyMutator<[Element]> where Value == [Element] {
        AnyMutator<[Element]>(ArrayDuplicationMutator<Element>())
    }

    public static func positionAware<Element: MutatorProviding & Sendable>() -> AnyMutator<[Element]> where Value == [Element] {
        AnyMutator<[Element]>(ArrayPositionAwareMutator<Element>())
    }

    public static func lengthTargeted<Element: MutatorProviding & Sendable>() -> AnyMutator<[Element]> where Value == [Element] {
        AnyMutator<[Element]>(ArrayLengthTargetedMutator<Element>())
    }

    public static func sequenceInsertion<Element: MutatorProviding & Sendable>() -> AnyMutator<[Element]> where Value == [Element] {
        AnyMutator<[Element]>(ArraySequenceInsertionMutator<Element>())
    }

    public static func repeatedValues<Element: MutatorProviding & Sendable>() -> AnyMutator<[Element]> where Value == [Element] {
        AnyMutator<[Element]>(ArrayRepeatedValuesMutator<Element>())
    }

    public static func comprehensive<Element: MutatorProviding & Sendable>() -> AnyMutator<[Element]> where Value == [Element] {
        AnyMutator<[Element]>(ComposedMutator([
            AnyMutator<[Element]>(ArrayDuplicationMutator<Element>()),
            AnyMutator<[Element]>(ArrayPositionAwareMutator<Element>()),
            AnyMutator<[Element]>(ArrayLengthTargetedMutator<Element>()),
            AnyMutator<[Element]>(ArraySequenceInsertionMutator<Element>()),
            AnyMutator<[Element]>(ArrayRepeatedValuesMutator<Element>()),
        ]))
    }
}

extension Array where Element: MutatorProviding & Sendable {
    /// Create a composed mutator from multiple array strategies.
    public static func mutators(_ mutators: AnyMutator<[Element]>...) -> AnyMutator<[Element]> {
        AnyMutator(ComposedMutator(mutators))
    }
}
