//
//  SeededRandomNumberGenerator.swift
//  PropertyTestingKit
//
//  A deterministic random number generator for reproducible tests.
//

import Foundation

/// A deterministic random number generator using a Linear Congruential Generator (LCG).
///
/// Use this in tests to make randomness reproducible by providing a fixed seed.
///
/// Example:
/// ```swift
/// var rng = SeededRandomNumberGenerator(seed: 12345)
/// let value = Int.random(in: 0..<100, using: &rng)  // Always produces the same sequence
/// ```
public struct SeededRandomNumberGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    /// Create a seeded random number generator.
    ///
    /// - Parameter seed: The seed value. The same seed always produces the same sequence.
    public init(seed: UInt64) {
        self.state = seed
    }

    /// Generate the next random UInt64.
    ///
    /// Uses the same LCG parameters as glibc for compatibility.
    public mutating func next() -> UInt64 {
        // LCG parameters (same as glibc)
        // state = (a * state + c) mod m
        // where a = 6364136223846793005, c = 1442695040888963407, m = 2^64
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
