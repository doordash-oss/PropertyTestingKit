//
//  Mutator.swift
//  PropertyTestingKit
//
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
///     mutate: { [$0 + 1, $0 - 1] },
///     generate: { rng in Int.random(in: Int.min...Int.max, using: &rng) }
/// )
/// ```
public struct Mutator<Value: Sendable>: Sendable {
    /// Seed values to start fuzzing with.
    public let seeds: [Value]

    /// Generate mutations of a value.
    public let mutate: @Sendable (Value) -> [Value]

    /// Generate a random value using the provided RNG.
    ///
    /// This is used when the seed queue is exhausted and fresh random
    /// inputs are needed to continue exploration.
    ///
    /// The RNG is passed in to avoid the overhead of fetching it via
    /// dependency injection on every call (millions of times per fuzz run).
    public let generate: @Sendable (inout FastRNG) -> Value

    /// Create a mutator with seeds, mutation function, and generation function.
    public init(
        seeds: [Value],
        mutate: @escaping @Sendable (Value) -> [Value],
        generate: @escaping @Sendable (inout FastRNG) -> Value
    ) {
        self.seeds = seeds
        self.mutate = mutate
        self.generate = generate
    }

    /// Create a mutator with seeds and mutation function.
    /// Generation will pick a random seed.
    public init(
        seeds: [Value],
        mutate: @escaping @Sendable (Value) -> [Value]
    ) {
        self.seeds = seeds
        self.mutate = mutate
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
    /// Seeds are concatenated, mutations are combined, and generation
    /// picks randomly from the component mutators.
    public static func compose(_ mutators: [Mutator<Value>]) -> Mutator<Value> {
        guard !mutators.isEmpty else {
            fatalError("Cannot compose empty mutator list")
        }

        return Mutator(
            seeds: mutators.flatMap(\.seeds),
            mutate: { value in
                mutators.flatMap { $0.mutate(value) }
            },
            generate: { rng in
                let index = Int.random(in: 0..<mutators.count, using: &rng)
                return mutators[index].generate(&rng)
            }
        )
    }

    /// Combine this mutator with another.
    public func combined(with other: Mutator<Value>) -> Mutator<Value> {
        Mutator.compose([self, other])
    }
}
