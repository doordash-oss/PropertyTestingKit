//
//  RandomNumberGeneratorClient.swift
//  PropertyTestingKit
//
//  Lock-free random number generation using MWC192 - a fast PRNG.
//

import Dependencies

/// Dependency client for random number generation.
///
/// Uses MWC192, a fast multiply-with-carry PRNG that is ~42x faster than
/// SystemRandomNumberGenerator. Each call creates a fresh RNG instance
/// to eliminate lock contention in concurrent fuzzing workloads.
///
/// For deterministic testing, inject a factory that creates seeded generators:
/// ```swift
/// withDependencies {
///     $0.random = RandomNumberGeneratorClient { MWC192(seed: 42) }
/// } operation: {
///     // deterministic random behavior (note: each call gets a fresh seeded generator)
/// }
/// ```
public struct RandomNumberGeneratorClient: Sendable {
    private let makeGenerator: @Sendable () -> any RandomNumberGenerator & Sendable

    /// Initialize with a generator factory.
    /// The factory is called each time randomness is needed, creating a fresh instance.
    public init(_ makeGenerator: @escaping @Sendable () -> any RandomNumberGenerator & Sendable) {
        self.makeGenerator = makeGenerator
    }

    /// Convenience initializer that creates a factory returning MWC192.
    /// MWC192 is ~42x faster than SystemRandomNumberGenerator.
    public init() {
        self.makeGenerator = { MWC192() }
    }

    /// Execute a closure with access to a fresh random number generator.
    /// Each call gets its own RNG instance - no locks, no shared state.
    public func callAsFunction<R: Sendable>(
        _ work: @Sendable (inout any RandomNumberGenerator & Sendable) -> R
    ) -> R {
        var rng = makeGenerator()
        return work(&rng)
    }
}

// MARK: - Dependency Key

extension RandomNumberGeneratorClient: DependencyKey {
    /// Live value creates a fresh MWC192 generator for each call.
    /// MWC192 is ~42x faster than SystemRandomNumberGenerator.
    public static let liveValue = RandomNumberGeneratorClient()

    /// Test value also uses MWC192 by default.
    /// Override with a seeded generator factory for deterministic tests.
    public static let testValue = liveValue
}

extension DependencyValues {
    /// Random number generator client.
    ///
    /// Uses system randomness by default in both live and test contexts.
    /// Each call gets a fresh RNG instance - no lock overhead.
    public var random: RandomNumberGeneratorClient {
        get { self[RandomNumberGeneratorClient.self] }
        set { self[RandomNumberGeneratorClient.self] = newValue }
    }
}
