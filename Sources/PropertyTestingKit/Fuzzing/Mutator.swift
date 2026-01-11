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
///     public static var defaultMutator: AnyMutator<MyType> {
///         AnyMutator(seeds: [...]) { value in [...] }
///     }
/// }
/// ```
public protocol MutatorProviding: Sendable {
    /// The default mutator for this type.
    static var defaultMutator: AnyMutator<Self> { get }
}

// MARK: - Mutator Protocol

/// A type that can generate seed values, mutations, and random values for fuzzing.
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
/// // Combine multiple strategies
/// try fuzz(using: Int.mutators(.boundaries, .ports)) { (port: Int) in
///     testConnection(port: port)
/// }
/// ```
public protocol Mutator<Value>: Sendable {
    associatedtype Value: Sendable

    /// Seed values to start fuzzing with.
    var seeds: [Value] { get }

    /// Generate mutations of a value.
    func mutate(_ value: Value) -> [Value]

    /// Generate a random value.
    ///
    /// This is used when the seed queue is exhausted and fresh random
    /// inputs are needed to continue exploration.
    ///
    /// Uses the `@Dependency(\.random)` client for random number generation,
    /// which can be overridden in tests for determinism.
    func generate() -> Value
}

// MARK: - AnyMutator (Type Erasure)

/// A type-erased mutator.
public struct AnyMutator<Value: Sendable>: Mutator, Sendable {
    private let _seeds: @Sendable () -> [Value]
    private let _mutate: @Sendable (Value) -> [Value]
    private let _generate: @Sendable () -> Value

    public var seeds: [Value] { _seeds() }

    public func mutate(_ value: Value) -> [Value] {
        _mutate(value)
    }

    public func generate() -> Value {
        _generate()
    }

    public init<M: Mutator>(_ mutator: M) where M.Value == Value {
        self._seeds = { mutator.seeds }
        self._mutate = { mutator.mutate($0) }
        self._generate = { mutator.generate() }
    }

    public init(
        seeds: [Value],
        mutate: @escaping @Sendable (Value) -> [Value],
        generate: @escaping @Sendable () -> Value
    ) {
        self._seeds = { seeds }
        self._mutate = mutate
        self._generate = generate
    }

    /// Convenience initializer that picks randomly from seeds for generation.
    public init(seeds: [Value], mutate: @escaping @Sendable (Value) -> [Value]) {
        @Dependency(\.random) var random
        self._seeds = { seeds }
        self._mutate = mutate
        self._generate = {
            // Default: pick a random seed
            let seedList = seeds
            guard !seedList.isEmpty else {
                fatalError("Cannot generate from empty seeds")
            }
            return random { rng in
                let index = Int.random(in: 0..<seedList.count, using: &rng)
                return seedList[index]
            }
        }
    }
}

// MARK: - ComposedMutator

/// A mutator that combines multiple mutation strategies.
public struct ComposedMutator<Value: Sendable>: Mutator, Sendable {
    @Dependency(\.random) private var random

    private let mutators: [AnyMutator<Value>]

    public var seeds: [Value] {
        mutators.flatMap(\.seeds)
    }

    public func mutate(_ value: Value) -> [Value] {
        mutators.flatMap { $0.mutate(value) }
    }

    public func generate() -> Value {
        // Pick a random mutator and use its generator
        guard !mutators.isEmpty else {
            fatalError("Cannot generate from empty ComposedMutator")
        }
        let index = random { rng in
            Int.random(in: 0..<mutators.count, using: &rng)
        }
        return mutators[index].generate()
    }

    public init(_ mutators: [AnyMutator<Value>]) {
        self.mutators = mutators
    }
}

// MARK: - SingleMutator

/// A mutator with a single strategy.
public struct SingleMutator<Value: Sendable>: Mutator, Sendable {
    @Dependency(\.random) private var random

    public let seeds: [Value]
    private let _mutate: @Sendable (Value) -> [Value]
    private let _generate: (@Sendable () -> Value)?

    public func mutate(_ value: Value) -> [Value] {
        _mutate(value)
    }

    public func generate() -> Value {
        if let customGenerate = _generate {
            return customGenerate()
        } else {
            // Default: pick a random seed
            guard !seeds.isEmpty else {
                fatalError("Cannot generate from empty seeds")
            }
            return random { rng in
                let index = Int.random(in: 0..<seeds.count, using: &rng)
                return seeds[index]
            }
        }
    }

    public init(seeds: [Value], mutate: @escaping @Sendable (Value) -> [Value]) {
        self.seeds = seeds
        self._mutate = mutate
        self._generate = nil
    }

    public init(
        seeds: [Value],
        mutate: @escaping @Sendable (Value) -> [Value],
        generate: @escaping @Sendable () -> Value
    ) {
        self.seeds = seeds
        self._mutate = mutate
        self._generate = generate
    }
}
