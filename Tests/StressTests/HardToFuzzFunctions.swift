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

/// Extreme: Dynamic string matching
/// The magic string is constructed at runtime, making it invisible to static analysis
public func extremeDynamicPassword(_ str: String) -> String {
    let year = "2024"
    let secret = "token_" + year + "_secret"  // "token_2024_secret"
    if str == secret {
        return "dynamic-match"
    } else {
        return "dynamic-mismatch"
    }
}

/// Extreme: Multiple dynamic string checks
public func extremeMultipleDynamicStrings(_ str: String) -> String {
    let prefix = "admin"
    let suffix = "_root"
    let expected = prefix + suffix  // "admin_root"

    if str == expected {
        return "full-match"
    } else if str.hasPrefix(prefix) {
        return "prefix-match"
    } else if str.hasSuffix(suffix) {
        return "suffix-match"
    } else {
        return "no-match"
    }
}

// MARK: - Difficulty Level: Loop-based
// Loop patterns that test iteration-sensitive coverage

/// Easy Loop: Find first element greater than threshold
/// Tests basic loop with early exit
public func easyLoopFindFirst(_ values: [Int], threshold: Int) -> String {
    for value in values {
        if value > threshold {
            return "found"
        }
    }
    return "not-found"
}

/// Easy Loop: Count elements matching a condition
public func easyLoopCount(_ values: [Int], target: Int) -> String {
    var count = 0
    for value in values {
        if value == target {
            count += 1
        }
    }
    if count >= 3 {
        return "many-matches"
    } else if count > 0 {
        return "few-matches"
    } else {
        return "no-matches"
    }
}

/// Medium Loop: Accumulator with threshold
/// Sum values until we exceed a threshold
public func mediumLoopAccumulator(_ values: [Int], threshold: Int) -> String {
    var sum = 0
    for value in values {
        sum &+= value  // Wrapping add
        if sum > threshold {
            return "threshold-exceeded"
        }
    }
    if sum == threshold {
        return "exact-threshold"
    }
    return "below-threshold"
}

/// Medium Loop: Index-dependent condition
/// Different behavior on specific iteration indices
public func mediumLoopIndexDependent(_ values: [Int]) -> String {
    for (index, value) in values.enumerated() {
        if index == 3 && value == 42 {
            return "magic-at-index-3"
        }
        if index == 7 && value < 0 {
            return "negative-at-index-7"
        }
    }
    return "normal"
}

/// Medium Loop: General index check for indices 1-20
/// Tests that array mutations work for arbitrary indices, not just hardcoded 3 and 7
/// Returns "hit-N" if values[N] < 0 for the given targetIndex N
public func mediumLoopGeneralIndexCheck(_ values: [Int], targetIndex: Int) -> String {
    guard targetIndex >= 1 && targetIndex <= 20 else {
        return "invalid-index"
    }
    guard values.count > targetIndex else {
        return "array-too-short"
    }
    if values[targetIndex] < 0 {
        return "hit-\(targetIndex)"
    }
    return "not-negative"
}

/// Hard Loop: Nested loops with break condition
/// Find a specific pair in nested iteration
public func hardLoopNestedFind(_ outer: [Int], _ inner: [Int]) -> String {
    for a in outer {
        for b in inner {
            if a == 42 && b == 1337 {
                return "magic-pair"
            }
            if a + b == 100 {
                return "sum-100"
            }
        }
    }
    return "no-special-pair"
}

/// Hard Loop: State machine with transitions
/// Process input sequence through state transitions
public func hardLoopStateMachine(_ inputs: [Int]) -> String {
    enum State { case idle, processing, error, success }
    var state: State = .idle

    for input in inputs {
        switch state {
        case .idle:
            if input == 1 {
                state = .processing
            } else if input < 0 {
                state = .error
            }
        case .processing:
            if input == 2 {
                state = .success
            } else if input == 0 {
                state = .idle
            } else if input < 0 {
                state = .error
            }
        case .error, .success:
            break  // Terminal states
        }
    }

    switch state {
    case .idle: return "remained-idle"
    case .processing: return "still-processing"
    case .error: return "ended-error"
    case .success: return "ended-success"
    }
}

/// Very Hard Loop: Sequence pattern detection
/// Must find specific sequence [1, 2, 3] in order
public func veryHardLoopSequenceDetect(_ values: [Int]) -> String {
    var matchIndex = 0
    let pattern = [1, 2, 3]

    for value in values {
        if value == pattern[matchIndex] {
            matchIndex += 1
            if matchIndex == pattern.count {
                return "pattern-found"
            }
        } else if value == pattern[0] {
            matchIndex = 1
        } else {
            matchIndex = 0
        }
    }
    return "pattern-not-found"
}

/// Very Hard Loop: Checksum validation
/// Compute rolling checksum and validate at end
public func veryHardLoopChecksum(_ values: [Int]) -> String {
    guard !values.isEmpty else { return "empty-input" }

    var checksum = 0
    for (index, value) in values.enumerated() {
        checksum = (checksum &* 31) &+ value &+ index
    }

    // Checksum must match a specific value
    let normalizedChecksum = checksum & 0xFFFF
    if normalizedChecksum == 0x1234 {
        return "valid-checksum"
    } else if normalizedChecksum == 0 {
        return "zero-checksum"
    }
    return "invalid-checksum"
}

/// Extreme Loop: Matrix search with constraints
/// Find cell where row*col product equals target AND both coordinates satisfy constraints
public func extremeLoopMatrixSearch(_ rows: Int, _ cols: Int, target: Int) -> String {
    guard rows > 0 && rows <= 100 && cols > 0 && cols <= 100 else {
        return "invalid-dimensions"
    }

    for row in 0..<rows {
        for col in 0..<cols {
            let product = row &* col
            if product == target && row > 10 && col > 5 {
                return "constrained-match"
            }
            if product == target {
                return "unconstrained-match"
            }
        }
    }
    return "no-match"
}

/// Extreme Loop: Convergence test
/// Iterate until value converges or max iterations
public func extremeLoopConvergence(_ start: Int, divisor: Int) -> String {
    guard divisor > 1 else { return "invalid-divisor" }

    var value = start
    var iterations = 0
    let maxIterations = 1000

    while value != 1 && iterations < maxIterations {
        if value % divisor == 0 {
            value = value / divisor
        } else {
            value = value &+ 1
        }
        iterations += 1
    }

    if value == 1 && iterations == 42 {
        return "magic-convergence"
    } else if value == 1 {
        return "converged"
    }
    return "did-not-converge"
}

// MARK: - Difficulty Level: Large Arrays
// Tests that require arrays to grow significantly through mutations

/// Requires array of 100+ elements with a negative value somewhere
/// Tests that array doubling mutations can grow arrays to significant sizes
public func largeArrayWithNegative(_ values: [Int]) -> String {
    guard values.count >= 100 else {
        return "too-small"
    }
    if values.contains(where: { $0 < 0 }) {
        return "large-with-negative"
    }
    return "large-all-positive"
}

/// Requires array of 200+ elements
/// Tests deeper array growth through repeated doubling
public func veryLargeArray(_ values: [Int]) -> String {
    guard values.count >= 200 else {
        return "too-small"
    }
    return "very-large"
}

// MARK: - Coverage Tracking Helpers

/// Tracks which branches have been covered in a test run
public actor CoverageTracker {
    private var covered: Set<String> = []

    public init() {}

    public func record(_ branch: String) {
        covered.insert(branch)
    }

    public func coveredBranches() -> Set<String> {
        covered
    }

    public func reset() {
        covered.removeAll()
    }

    public func coverageRatio(of expected: Set<String>) -> Double {
        guard !expected.isEmpty else { return 1.0 }
        return Double(covered.intersection(expected).count) / Double(expected.count)
    }
}
