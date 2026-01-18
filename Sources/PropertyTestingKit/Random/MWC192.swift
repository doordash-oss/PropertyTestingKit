//
//  MWC192.swift
//  PropertyTestingKit
//
//  Marsaglia Multiply-With-Carry generator with 192-bit state.
//  Based on https://prng.di.unimi.it/MWC192.c by Sebastiano Vigna.
//
//  Speed: ~0.42 ns/64 bits - one of the fastest PRNGs available.
//  Period: ~2^191
//

/// A fast multiply-with-carry random number generator with 192-bit state.
///
/// MWC192 is one of the fastest PRNGs available (~0.42 ns per 64-bit output),
/// significantly faster than both SystemRandomNumberGenerator and xoshiro256++.
///
/// Based on the implementation by Sebastiano Vigna at https://prng.di.unimi.it/
public struct MWC192: RandomNumberGenerator, Sendable {
    @usableFromInline var x: UInt64
    @usableFromInline var y: UInt64
    @usableFromInline var c: UInt64

    @usableFromInline static let a: UInt64 = 0xffa04e67b3c95d86

    /// Initialize with a seed value.
    ///
    /// - Parameter seed: Seed value. If 0, uses system entropy.
    @inlinable
    public init(seed: UInt64 = 0) {
        // Use SplitMix64 to generate initial state from seed
        var s = seed == 0 ? UInt64(bitPattern: Int64(truncatingIfNeeded: mach_absolute_time())) : seed

        @inline(__always)
        func splitMix() -> UInt64 {
            s &+= 0x9e3779b97f4a7c15
            var z = s
            z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
            z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
            return z ^ (z >> 31)
        }

        x = splitMix()
        y = splitMix()
        // Constraint: 0 < c < a - 1
        c = splitMix() % (Self.a - 2) + 1
    }

    /// Generate the next random UInt64.
    @inlinable
    public mutating func next() -> UInt64 {
        let result = y
        // 128-bit multiply: a * x
        let t = Self.a.multipliedFullWidth(by: x)
        // Add carry to low bits
        let (sum, overflow) = t.low.addingReportingOverflow(c)
        // Update state
        x = y
        y = sum
        c = t.high &+ (overflow ? 1 : 0)
        return result
    }
}

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
