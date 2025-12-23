//
//  RandomNumberGeneratorClient.swift
//  PropertyTestingKit
//
//  Wrapper around withRandomNumberGenerator that uses live value in tests by default.
//

import Dependencies

/// Dependency client for random number generation.
///
/// This wraps the `withRandomNumberGenerator` dependency from swift-dependencies
/// but uses the live (system) random number generator as the test value by default.
/// This avoids requiring every test to inject a random number generator.
///
/// Tests that need deterministic randomness can override with a seeded generator:
/// ```swift
/// withDependencies {
///     $0.random = RandomNumberGeneratorClient(SeededRandomNumberGenerator(seed: 42))
/// } operation: {
///     // deterministic random behavior
/// }
/// ```
public struct RandomNumberGeneratorClient: Sendable {
    private let generator: LockIsolated<any RandomNumberGenerator & Sendable>

    public init(_ generator: some RandomNumberGenerator & Sendable) {
        self.generator = LockIsolated(generator)
    }

    /// Execute a closure with access to the random number generator.
    public func callAsFunction<R: Sendable>(
        _ work: @Sendable (inout any RandomNumberGenerator & Sendable) -> R
    ) -> R {
        generator.withValue { rng in
            work(&rng)
        }
    }
}

// MARK: - Dependency Key

extension RandomNumberGeneratorClient: DependencyKey {
    /// Live value uses the system random number generator.
    public static let liveValue = RandomNumberGeneratorClient(SystemRandomNumberGenerator())

    /// Test value also uses the system random number generator by default.
    /// This avoids requiring tests to inject a generator unless they need determinism.
    public static let testValue = liveValue
}

extension DependencyValues {
    /// Random number generator client.
    ///
    /// Uses system randomness by default in both live and test contexts.
    /// Override with a seeded generator for deterministic tests.
    public var random: RandomNumberGeneratorClient {
        get { self[RandomNumberGeneratorClient.self] }
        set { self[RandomNumberGeneratorClient.self] = newValue }
    }
}
