//
//  Fuzzable.swift
//  PropertyTestingKit
//
//  Protocol for types that can be fuzzed with coverage guidance.
//

import Foundation

// MARK: - Fuzzable Protocol

/// A type that can generate test values and mutations for fuzzing.
///
/// Conforming types provide:
/// - `fuzz`: An array of interesting boundary values
/// - `mutate(_:)`: Generate variations of an existing value
///
/// The combination enables coverage-guided fuzzing: start with boundary
/// values, then mutate interesting inputs to explore nearby code paths.
///
/// ## Basic Conformance
///
/// For simple types, provide boundary values:
///
/// ```swift
/// extension MyEnum: Fuzzable {
///     static var fuzz: [MyEnum] { [.case1, .case2, .case3] }
/// }
/// ```
///
/// ## Mutation
///
/// The default mutation for enums cycles through all cases.
/// For structs/classes, override `mutate` to tweak individual fields:
///
/// ```swift
/// extension Config: Fuzzable {
///     static var fuzz: [Config] { /* boundary configs */ }
///
///     func mutate() -> [Config] {
///         // Mutate each field independently
///         timeout.mutate().map { Config(timeout: $0, retries: retries) } +
///         retries.mutate().map { Config(timeout: timeout, retries: $0) }
///     }
/// }
/// ```
public protocol Fuzzable {
    /// Boundary values to start fuzzing with.
    ///
    /// These should be "interesting" values that are likely to trigger
    /// different code paths: empty values, maximum values, edge cases, etc.
    static var fuzz: [Self] { get }

    /// Generate mutations of this value.
    ///
    /// Mutations should be "close" to the original value - small changes
    /// that might trigger nearby code paths. For example:
    /// - Numbers: increment, decrement, negate, halve, double
    /// - Strings: append, truncate, change case
    /// - Structs: mutate one field at a time
    ///
    /// Returns an empty array if no mutations are possible.
    func mutate() -> [Self]
}

// MARK: - Default Mutation

extension Fuzzable where Self: Equatable {
    /// Default mutation returns all fuzz values except the current one.
    ///
    /// This provides basic mutation for types where field-level mutation
    /// doesn't make sense (like enums).
    public func mutate() -> [Self] {
        Self.fuzz.filter { $0 != self }
    }
}

// MARK: - Bool Conformance

extension Bool: Fuzzable {
    public static var fuzz: [Bool] {
        [true, false]
    }

    public func mutate() -> [Bool] {
        [!self]
    }
}

// MARK: - Int Conformance

extension Int: Fuzzable {
    public static var fuzz: [Int] {
        [
            // Extremes and zero
            0,
            1,
            -1,
            Int.max,
            Int.min,

            // Small values useful for arithmetic relationships
            3,       // Common in b = a*k + 3 patterns
            7,       // Common factor
            10,      // Base 10

            // Common magic numbers (from security/hacking culture)
            42,      // "Answer to everything"
            1337,    // "leet" - extremely common in tests
            31337,   // "elite" - another common magic

            // Common range boundaries
            100,
            200,
            255,     // Max unsigned byte
            256,     // Byte overflow
            1000,
            1024,    // Power of 2

            // Values useful for divisibility tests
            77,      // 7 * 11
            1155,    // 3 * 5 * 7 * 11, in range [1001, 1999]

            // Large values
            1_000_000,
            -1_000_000,
        ]
    }

    public func mutate() -> [Int] {
        var mutations: [Int] = []

        // Basic arithmetic mutations (with overflow protection)
        if self != Int.max { mutations.append(self + 1) }
        if self != Int.min { mutations.append(self - 1) }
        if self != 0 && self != Int.min { mutations.append(-self) }  // -Int.min overflows
        if self != 0 { mutations.append(self / 2) }
        if self > 0 && self <= Int.max / 2 { mutations.append(self * 2) }
        if self < 0 && self >= Int.min / 2 { mutations.append(self * 2) }

        // Bit manipulation
        if self != 0 { mutations.append(self ^ 1) }  // Flip LSB

        // Divisibility-aware mutations: try nearby multiples of common factors
        for factor in [7, 11, 13, 77] {
            let nearestMultiple = (self / factor) * factor
            if nearestMultiple != self && nearestMultiple != 0 {
                mutations.append(nearestMultiple)
            }
            // Also try the next multiple up
            let (next, overflow) = nearestMultiple.addingReportingOverflow(factor)
            if !overflow && next != self {
                mutations.append(next)
            }
        }

        return mutations
    }
}

// MARK: - String Conformance

extension String: Fuzzable {
    // Cache the fuzz array to avoid regenerating the 1000-char string on each access
    private static let _cachedFuzz: [String] = [
        // Empty and whitespace
        "",
        " ",
        "\t\n\r",

        // Various lengths (1-6 chars for length-based tests)
        "a",
        "ab",
        "abc",
        "abcd",
        "abcde",    // Length 5 - common test case
        "abcdef",

        // Common magic strings
        "xyzzy",    // Classic adventure game magic word
        "plugh",    // Another classic magic word
        "test",
        "admin",
        "password",

        // Common prefixes
        "SECRET_x",
        "PRIVATE_",
        "API_KEY_",
        "TOKEN_",

        // Unicode and special
        "😄",
        "\0",
        "Hello World",
        "Hello\nWorld",
        "Hello!@#$%^&*()_+-=[]{}|;:,.<>?",

        // Long string
        String(repeating: "a", count: 1000),
    ]

    public static var fuzz: [String] { _cachedFuzz }

    public func mutate() -> [String] {
        var mutations: [String] = []

        // Length mutations
        if !isEmpty {
            mutations.append(String(dropLast()))
            mutations.append(String(dropFirst()))
        }
        mutations.append(self + "x")
        mutations.append("x" + self)

        // Case mutations
        mutations.append(uppercased())
        mutations.append(lowercased())

        // Character mutations
        if !isEmpty {
            var chars = Array(self)
            chars[0] = "X"
            mutations.append(String(chars))
        }

        // Whitespace mutations
        mutations.append(self + " ")
        mutations.append(" " + self)
        mutations.append(trimmingCharacters(in: .whitespaces))

        // Prefix mutations - try common prefixes
        for prefix in ["SECRET_", "PRIVATE_", "API_", "TOKEN_"] {
            if !self.hasPrefix(prefix) {
                mutations.append(prefix + self)
            }
        }

        // Length-targeted mutations: try to hit common lengths
        for targetLen in [5, 8, 16, 32] {
            if count < targetLen {
                mutations.append(self + String(repeating: "x", count: targetLen - count))
            } else if count > targetLen && targetLen > 0 {
                mutations.append(String(prefix(targetLen)))
            }
        }

        return mutations.filter { $0 != self }
    }
}

// MARK: - Optional Conformance

extension Optional: Fuzzable where Wrapped: Fuzzable {
    public static var fuzz: [Optional<Wrapped>] {
        [nil] + Wrapped.fuzz.map { .some($0) }
    }

    public func mutate() -> [Optional<Wrapped>] {
        switch self {
        case .none:
            return Wrapped.fuzz.map { .some($0) }
        case .some(let wrapped):
            return [nil] + wrapped.mutate().map { .some($0) }
        }
    }
}

// MARK: - Array Conformance

extension Array: Fuzzable where Element: Fuzzable {
    public static var fuzz: [[Element]] {
        var result: [[Element]] = [[]]

        let elementSeeds = Array(Element.fuzz.prefix(3))
        guard !elementSeeds.isEmpty else { return result }

        // Single element arrays with first few seeds
        for element in elementSeeds {
            result.append([element])
        }

        // Small multi-element array from seeds (provides variety)
        if elementSeeds.count >= 3 {
            result.append(elementSeeds)
        }

        return result
    }

    public func mutate() -> [[Element]] {
        var mutations: [[Element]] = []

        // === Removal mutations ===
        for i in indices {
            var copy = self
            copy.remove(at: i)
            mutations.append(copy)
        }

        // === Append elements (incremental growth) ===
        for element in Element.fuzz.prefix(3) {
            mutations.append(self + [element])
        }

        // === Prepend element ===
        for element in Element.fuzz.prefix(2) {
            mutations.append([element] + self)
        }

        // === Array doubling (exponential growth) ===
        // No cap - allows arrays to grow to any size needed.
        // Value profile guidance will prioritize growth when comparisons
        // like `count >= 100` are encountered.
        if count > 0 {
            mutations.append(self + self)
        }

        // === Mutate individual elements ===
        for i in indices {
            for mutated in self[i].mutate().prefix(2) {
                var copy = self
                copy[i] = mutated
                mutations.append(copy)
            }
        }

        // === Reversal ===
        if count > 1 {
            mutations.append(reversed())
        }

        return mutations
    }
}

// MARK: - Double Conformance

extension Double: Fuzzable {
    public static var fuzz: [Double] {
        [
            0.0,
            1.0,
            -1.0,
            0.5,
            -0.5,
            Double.greatestFiniteMagnitude,
            -Double.greatestFiniteMagnitude,
            Double.leastNormalMagnitude,
            Double.nan,
            Double.infinity,
            -Double.infinity,
        ]
    }

    public func mutate() -> [Double] {
        guard isFinite else { return [0.0, 1.0, -1.0] }

        var mutations: [Double] = []
        mutations.append(self + 1)
        mutations.append(self - 1)
        mutations.append(-self)
        if self != 0 { mutations.append(self / 2) }
        mutations.append(self * 2)
        mutations.append(self + 0.1)
        mutations.append(self - 0.1)
        return mutations
    }
}

// MARK: - UInt Conformance

extension UInt: Fuzzable {
    public static var fuzz: [UInt] {
        [0, 1, UInt.max, UInt.max / 2, 42, 100, 1000]
    }

    public func mutate() -> [UInt] {
        var mutations: [UInt] = []
        if self != UInt.max { mutations.append(self + 1) }
        if self != 0 { mutations.append(self - 1) }
        if self != 0 { mutations.append(self / 2) }
        if self != 0 && self <= UInt.max / 2 { mutations.append(self * 2) }  // 0 * 2 = 0
        return mutations
    }
}

// MARK: - Character Conformance

extension Character: Fuzzable {
    public static var fuzz: [Character] {
        ["a", "Z", "0", " ", "\n", "\t", "😄", "\0"]
    }

    public func mutate() -> [Character] {
        Self.fuzz.filter { $0 != self }
    }
}
