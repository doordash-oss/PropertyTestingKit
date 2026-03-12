//
//  ArrayMutators.swift
//  PropertyTestingKit
//
//  Built-in array mutation strategies for fuzz testing.
//

// MARK: - Array Mutator Static Properties

extension Mutator {
    public static func duplication<Element: MutatorProviding & Sendable>() -> Mutator<[Element]> where Value == [Element] {
        arrayDuplicationMutator()
    }

    public static func positionAware<Element: MutatorProviding & Sendable>() -> Mutator<[Element]> where Value == [Element] {
        arrayPositionAwareMutator()
    }

    public static func lengthTargeted<Element: MutatorProviding & Sendable>() -> Mutator<[Element]> where Value == [Element] {
        arrayLengthTargetedMutator()
    }

    public static func sequenceInsertion<Element: MutatorProviding & Sendable>() -> Mutator<[Element]> where Value == [Element] {
        arraySequenceInsertionMutator()
    }

    public static func repeatedValues<Element: MutatorProviding & Sendable>() -> Mutator<[Element]> where Value == [Element] {
        arrayRepeatedValuesMutator()
    }

    public static func comprehensive<Element: MutatorProviding & Sendable>() -> Mutator<[Element]> where Value == [Element] {
        Mutator<[Element]>.compose([
            arrayDuplicationMutator(),
            arrayPositionAwareMutator(),
            arrayLengthTargetedMutator(),
            arraySequenceInsertionMutator(),
            arrayRepeatedValuesMutator(),
        ])
    }
}

extension Array where Element: MutatorProviding & Sendable {
    /// Create a composed mutator from multiple array strategies.
    public static func mutators(_ mutators: Mutator<[Element]>...) -> Mutator<[Element]> {
        Mutator.compose(mutators)
    }
}
