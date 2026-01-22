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
///     public static var defaultMutator: MyTypeMutator {
///         MyTypeMutator()
///     }
/// }
/// ```
///
/// Using an associated type allows concrete mutator types (structs) to be
/// returned directly, avoiding type erasure overhead in the hot path.
public protocol MutatorProviding: Sendable {
    /// The concrete mutator type for this type.
    associatedtype DefaultMutator: Mutator where DefaultMutator.Value == Self

    /// The default mutator for this type.
    static var defaultMutator: DefaultMutator { get }
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

// Base class for type erasure - uses virtual dispatch instead of closure boxing
private class _AnyMutatorBoxBase<Value: Sendable>: @unchecked Sendable {
    var seeds: [Value] { fatalError("abstract") }
    func mutate(_ value: Value) -> [Value] { fatalError("abstract") }
    func generate() -> Value { fatalError("abstract") }
}

// Concrete box holding an actual Mutator
private final class _MutatorBox<M: Mutator>: _AnyMutatorBoxBase<M.Value>, @unchecked Sendable where M: Sendable {
    let base: M

    init(_ base: M) { self.base = base }

    override var seeds: [M.Value] { base.seeds }
    override func mutate(_ value: M.Value) -> [M.Value] { base.mutate(value) }
    override func generate() -> M.Value { base.generate() }
}

/// A type-erased mutator.
///
/// Uses class-based type erasure with virtual dispatch for better performance.
/// This avoids per-call retain/release overhead that closure boxing incurs.
public struct AnyMutator<Value: Sendable>: Mutator, Sendable {
    private let box: _AnyMutatorBoxBase<Value>

    public var seeds: [Value] { box.seeds }

    public func mutate(_ value: Value) -> [Value] {
        box.mutate(value)
    }

    public func generate() -> Value {
        box.generate()
    }

    /// Initialize with a concrete Mutator type.
    public init<M: Mutator>(_ mutator: M) where M.Value == Value {
        self.box = _MutatorBox(mutator)
    }

    /// Convenience initializer with seeds and mutation closure.
    /// Creates a SingleMutator internally for backward compatibility.
    public init(seeds: [Value], mutate: @escaping @Sendable (Value) -> [Value]) {
        self.init(SingleMutator(seeds: seeds, mutate: mutate))
    }

    /// Convenience initializer with seeds, mutation closure, and generate closure.
    /// Creates a SingleMutator internally for backward compatibility.
    public init(
        seeds: [Value],
        mutate: @escaping @Sendable (Value) -> [Value],
        generate: @escaping @Sendable () -> Value
    ) {
        self.init(SingleMutator(seeds: seeds, mutate: mutate, generate: generate))
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
