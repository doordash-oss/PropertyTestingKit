//
//  HardToFuzzFunctions.swift
//  StressTests
//
//  Functions with varying difficulty for coverage-guided fuzzing.
//  Used to stress test the fuzzer and identify weaknesses.
//

import Foundation

// MARK: - Difficulty Level: Easy
// Boundary conditions that seeds should handle

/// Easy: Greater-than comparison with reasonable boundary
/// Seeds like Int.max, 0, -1 should cover both branches
public func easyGreaterThan(_ num: Int) -> String {
    if num > 100 {
        return "above"
    } else {
        return "below"
    }
}

/// Easy: Negative check
/// Seeds include negative numbers
public func easyNegativeCheck(_ num: Int) -> String {
    if num < 0 {
        return "negative"
    } else {
        return "non-negative"
    }
}

/// Easy: Empty string check
/// Seeds include empty string
public func easyEmptyString(_ str: String) -> String {
    if str.isEmpty {
        return "empty"
    } else {
        return "non-empty"
    }
}

// MARK: - Difficulty Level: Medium
// Requires some mutation luck but achievable

/// Medium: Specific range check
/// Needs to find a number in [100, 200]
public func mediumRangeCheck(_ num: Int) -> String {
    if num >= 100 && num <= 200 {
        return "in-range"
    } else {
        return "out-of-range"
    }
}

/// Medium: String length check
/// Needs a string of exactly 5 characters
public func mediumLengthCheck(_ str: String) -> String {
    if str.count == 5 {
        return "five-chars"
    } else {
        return "other-length"
    }
}

/// Medium: Two conditions that must both be true
public func mediumTwoConditions(_ a: Int, _ b: Int) -> String {
    if a > 50 && b < 10 {
        return "both-true"
    } else {
        return "not-both"
    }
}

// MARK: - Difficulty Level: Hard
// Magic numbers - very unlikely to discover randomly

/// Hard: Exact equality check (magic number)
/// Probability of finding 12324 randomly is ~1/2^63
public func hardMagicNumber(_ num: Int) -> String {
    if num == 12324 {
        return "magic"
    } else {
        return "ordinary"
    }
}

/// Hard: Larger magic number
public func hardLargeMagicNumber(_ num: Int) -> String {
    if num == 98765432 {
        return "magic"
    } else {
        return "ordinary"
    }
}

/// Hard: Magic string
/// Must find exact string "xyzzy"
public func hardMagicString(_ str: String) -> String {
    if str == "xyzzy" {
        return "magic"
    } else {
        return "ordinary"
    }
}

/// Hard: Magic prefix
/// Must find string starting with "SECRET_"
public func hardMagicPrefix(_ str: String) -> String {
    if str.hasPrefix("SECRET_") {
        return "secret"
    } else {
        return "public"
    }
}

// MARK: - Difficulty Level: Very Hard
// Multiple magic values or nested conditions

/// Very Hard: Two magic numbers must match
public func veryHardTwoMagicNumbers(_ a: Int, _ b: Int) -> String {
    if a == 42 && b == 1337 {
        return "both-magic"
    } else if a == 42 {
        return "first-magic"
    } else if b == 1337 {
        return "second-magic"
    } else {
        return "neither"
    }
}

/// Very Hard: Checksum-like validation
/// The second number must be first * 7 + 3
/// Uses overflow-safe arithmetic to handle Int.max/Int.min seeds
public func veryHardChecksum(_ a: Int, _ b: Int) -> String {
    // Use overflow operators to avoid trapping on Int.max/Int.min
    let (product, overflow1) = a.multipliedReportingOverflow(by: 7)
    guard !overflow1 else { return "invalid-checksum" }
    let (sum, overflow2) = product.addingReportingOverflow(3)
    guard !overflow2 else { return "invalid-checksum" }

    if b == sum {
        return "valid-checksum"
    } else {
        return "invalid-checksum"
    }
}

/// Very Hard: Nested magic conditions
public func veryHardNestedMagic(_ num: Int) -> String {
    if num > 1000 {
        if num < 2000 {
            if num % 7 == 0 {
                if num % 11 == 0 {
                    // Must be in [1001, 1999], divisible by 77
                    // Only values: 1078, 1155, 1232, 1309, 1386, 1463, 1540, 1617, 1694, 1771, 1848, 1925
                    return "deeply-nested"
                }
                return "div-by-7"
            }
            return "in-range"
        }
        return "above-2000"
    }
    return "below-1000"
}

/// Very Hard: Hash comparison (simulated)
/// Requires finding input where hash matches target
public func veryHardHashMatch(_ str: String) -> String {
    // Simple "hash" - sum of character values mod 1000
    let hash = str.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 1000
    if hash == 777 {
        return "hash-match"
    } else {
        return "hash-mismatch"
    }
}

/// Very Hard: Modulo constraint with two integers
/// Requires finding (a, b) where (a + b) % 1000 == 777
/// This is solvable with modulo-aware pair mutations
public func veryHardModuloSum(_ a: Int, _ b: Int) -> String {
    let sum = a &+ b  // Wrapping add to avoid overflow traps
    let remainder = sum % 1000
    // Handle negative remainders
    let normalizedRemainder = remainder < 0 ? remainder + 1000 : remainder
    if normalizedRemainder == 777 {
        return "modulo-match"
    } else {
        return "modulo-mismatch"
    }
}

// MARK: - Difficulty Level: Extreme
// Practically impossible without value profile guidance or custom mutators

/// Extreme: 64-bit magic number
public func extremeMagic64(_ num: Int) -> String {
    if num == 0x7EAD_BEEF_CAFE_BABE {
        return "extreme-magic"
    } else {
        return "ordinary"
    }
}

/// Extreme: Must match exact sequence
public func extremeSequence(_ a: Int, _ b: Int, _ c: Int) -> String {
    if a == 111 && b == 222 && c == 333 {
        return "sequence-match"
    } else {
        return "sequence-mismatch"
    }
}

/// Extreme: Password-like string matching
public func extremePassword(_ str: String) -> String {
    if str == "Pr0p3rtyT3st1ng!" {
        return "access-granted"
    } else {
        return "access-denied"
    }
}

// MARK: - Coverage Tracking Helpers

/// Tracks which branches have been covered in a test run
public final class CoverageTracker: @unchecked Sendable {
    private var covered: Set<String> = []
    private let lock = NSLock()

    public init() {}

    public func record(_ branch: String) {
        lock.lock()
        covered.insert(branch)
        lock.unlock()
    }

    public func coveredBranches() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return covered
    }

    public func reset() {
        lock.lock()
        covered.removeAll()
        lock.unlock()
    }

    public func coverageRatio(of expected: Set<String>) -> Double {
        let covered = coveredBranches()
        guard !expected.isEmpty else { return 1.0 }
        return Double(covered.intersection(expected).count) / Double(expected.count)
    }
}
