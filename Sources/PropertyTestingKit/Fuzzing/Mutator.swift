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

//  Composable mutation strategies for fuzz testing.
//

import Dependencies
import Foundation

// MARK: - MutatorProviding Protocol

/// A type that provides a default mutator for fuzzing.
///
/// Conform to this protocol to enable the convenience `fuzz()` API
/// that automatically uses the type's default mutation strategy.
///
/// ## Usage
///
/// ```swift
/// extension MyType: MutatorProviding {
///     public static var defaultMutator: Mutator<MyType> {
///         Mutator(
///             seeds: [...],
///             mutate: { ... },
///             generate: { ... }
///         )
///     }
/// }
/// ```
public protocol MutatorProviding: Sendable {
    /// The default mutator for this type.
    static var defaultMutator: Mutator<Self> { get }
}

// MARK: - Mutator (Concrete Type)

/// A concrete mutator that generates seed values, mutations, and random values for fuzzing.
///
/// Mutators are composable mutation strategies that can be combined
/// and customized for domain-specific testing.
///
/// ## Usage
///
/// ```swift
/// // Use built-in mutators
/// try fuzz(using: String.mutators(.phoneNumbers, .emails)) { (input: String) in
///     validateInput(input)
/// }
///
/// // Create custom mutators
/// let customMutator = Mutator<Int>(
///     seeds: [0, 1, -1, Int.max],
///     mutate: { value, rng in Bool.random(using: &rng) ? value + 1 : value - 1 },
///     generate: { rng in Int.random(in: Int.min...Int.max, using: &rng) }
/// )
/// ```
public struct Mutator<Value: Sendable>: Sendable {
    /// Seed values to start fuzzing with.
    public let seeds: [Value]

    /// Produce ONE mutant of a value.
    ///
    /// Variety comes from the supplied RNG: a mutator that knows several
    /// mutation strategies picks one per call. Effort — how many mutants to
    /// draw from a value, and how many mutation steps to stack — belongs to
    /// the caller (the engine's scheduler), never to the mutator.
    public let mutate: @Sendable (Value, inout FastRNG) -> Value

    /// Generate a random value using the provided RNG.
    ///
    /// This is used when the seed queue is exhausted and fresh random
    /// inputs are needed to continue exploration.
    ///
    /// The RNG is passed in to avoid the overhead of fetching it via
    /// dependency injection on every call (millions of times per fuzz run).
    public let generate: @Sendable (inout FastRNG) -> Value

    /// Measure a value's real size (term node count, byte length, …) for the
    /// pool's REDUCE metric. When `nil` the pool falls back to the
    /// covered-edge count — a proxy that saturates once coverage does,
    /// leaving input growth invisible to REDUCE and capacity eviction.
    /// Called only on strategy-accepted inputs, never per iteration.
    public let size: (@Sendable (Value) -> Int)?

    /// Create a mutator with seeds, mutation function, and generation function.
    public init(
        seeds: [Value],
        mutate: @escaping @Sendable (Value, inout FastRNG) -> Value,
        generate: @escaping @Sendable (inout FastRNG) -> Value,
        size: (@Sendable (Value) -> Int)? = nil
    ) {
        self.seeds = seeds
        self.mutate = mutate
        self.generate = generate
        self.size = size
    }

    /// Create a mutator with seeds and mutation function.
    /// Generation will pick a random seed.
    public init(
        seeds: [Value],
        mutate: @escaping @Sendable (Value, inout FastRNG) -> Value,
        size: (@Sendable (Value) -> Int)? = nil
    ) {
        self.seeds = seeds
        self.mutate = mutate
        self.size = size
        // Default generate: pick a random seed
        self.generate = { rng in
            guard !seeds.isEmpty else {
                fatalError("Cannot generate from empty seeds")
            }
            let index = Int.random(in: 0..<seeds.count, using: &rng)
            return seeds[index]
        }
    }
}

// MARK: - Mutator Composition

extension Mutator {
    /// Combine multiple mutators into one.
    ///
    /// Seeds are concatenated; mutation and generation pick a random
    /// component mutator per call.
    public static func compose(_ mutators: [Mutator<Value>]) -> Mutator<Value> {
        guard !mutators.isEmpty else {
            fatalError("Cannot compose empty mutator list")
        }

        return Mutator(
            seeds: mutators.flatMap(\.seeds),
            mutate: { value, rng in
                let index = Int.random(in: 0..<mutators.count, using: &rng)
                return mutators[index].mutate(value, &rng)
            },
            generate: { rng in
                let index = Int.random(in: 0..<mutators.count, using: &rng)
                return mutators[index].generate(&rng)
            },
            // Size is a property of the Value, not the mutation strategy:
            // any component's measure serves the composite.
            size: mutators.lazy.compactMap(\.size).first
        )
    }

    /// Combine this mutator with another.
    public func combined(with other: Mutator<Value>) -> Mutator<Value> {
        Mutator.compose([self, other])
    }
}
