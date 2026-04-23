// Copyright 2026 DoorDash, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

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
