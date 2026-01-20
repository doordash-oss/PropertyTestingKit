//
//  Xoshiro256PlusPlus.swift
//  PropertyTestingKit
//
//  xoshiro256++ random number generator with 256-bit state.
//  Based on https://prng.di.unimi.it/xoshiro256plusplus.c by Sebastiano Vigna.
//
//  Speed: ~0.75 ns/64 bits
//  Period: 2^256 - 1
//

/// A fast xoshiro256++ random number generator with 256-bit state.
///
/// xoshiro256++ offers excellent statistical quality and good performance
/// (~0.75 ns per 64-bit output). It's widely used and well-tested.
///
/// Based on the implementation by Sebastiano Vigna at https://prng.di.unimi.it/
public struct Xoshiro256PlusPlus: RandomNumberGenerator, Sendable {
    @usableFromInline var s0: UInt64
    @usableFromInline var s1: UInt64
    @usableFromInline var s2: UInt64
    @usableFromInline var s3: UInt64

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

        s0 = splitMix()
        s1 = splitMix()
        s2 = splitMix()
        s3 = splitMix()
    }

    /// Generate the next random UInt64.
    @inlinable
    public mutating func next() -> UInt64 {
        let result = (s0 &+ s3).rotatedLeft(by: 23) &+ s0
        let t = s1 << 17

        s2 ^= s0
        s3 ^= s1
        s1 ^= s2
        s0 ^= s3
        s2 ^= t
        s3 = s3.rotatedLeft(by: 45)

        return result
    }
}

extension UInt64 {
    @inlinable @inline(__always)
    func rotatedLeft(by n: Int) -> UInt64 {
        (self << n) | (self >> (64 - n))
    }
}

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
