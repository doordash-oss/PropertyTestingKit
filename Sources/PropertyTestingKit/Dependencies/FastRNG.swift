//
//  FastRNG.swift
//  PropertyTestingKit
//
//  Thread-local XorShift64 random number generator for high-performance
//  random number generation in mutators without lock contention.
//

import Darwin
import Dependencies

/// Thread-local random number generator using XorShift64.
///
/// Uses pthread TLS for zero-allocation, lock-free random number generation.
/// Each thread maintains its own state, seeded from the thread ID on first access.
///
/// Performance: ~20ns per call with no allocation or lock overhead.
@usableFromInline
enum ThreadLocalRNG {
    @usableFromInline
    static let _key: pthread_key_t = {
        var key: pthread_key_t = 0
        pthread_key_create(&key, nil)
        return key
    }()

    /// Generate a random UInt64 using thread-local XorShift64.
    @inlinable
    static func next() -> UInt64 {
        let rawPtr = pthread_getspecific(_key)
        var state: UInt64
        if rawPtr == nil {
            // Seed from thread ID on first access
            state = UInt64(bitPattern: Int64(Int(bitPattern: pthread_self())))
            if state == 0 { state = 0xDEADBEEF }
        } else {
            state = UInt64(UInt(bitPattern: rawPtr))
        }
        // XorShift64
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        pthread_setspecific(_key, UnsafeRawPointer(bitPattern: UInt(truncatingIfNeeded: state)))
        return state
    }

    /// Generate a random integer in [0, upperBound).
    @inlinable
    static func random(upperBound: Int) -> Int {
        Int(next() % UInt64(upperBound))
    }
}

/// A fast random number generator conforming to `RandomNumberGenerator`.
///
/// Uses thread-local XorShift64 for zero-allocation random number generation.
/// Suitable for use with Swift's standard library random APIs.
///
/// ```swift
/// var rng = FastRNG()
/// let value = Int.random(in: 0..<100, using: &rng)
/// ```
public struct FastRNG: RandomNumberGenerator, Sendable {
    @inlinable
    public init() {}

    @inlinable
    public mutating func next() -> UInt64 {
        ThreadLocalRNG.next()
    }
}

// MARK: - Dependency Key

extension FastRNG: DependencyKey {
    public static let liveValue = FastRNG()
    public static let testValue = FastRNG()
}

extension DependencyValues {
    /// Fast random number generator using thread-local XorShift64.
    ///
    /// Zero allocation overhead - suitable for high-throughput fuzzing.
    var fastRNG: FastRNG {
        get { self[FastRNG.self] }
        set { self[FastRNG.self] = newValue }
    }
}
