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
            0,
            1,
            -1,
            1_000_000,
            -1_000_000,
            Int.max,
            Int.min,
            42,  // A "normal" value
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

        return mutations
    }
}

// MARK: - String Conformance

extension String: Fuzzable {
    public static var fuzz: [String] {
        [
            "",                                          // Empty
            "a",                                         // Single char
            String(repeating: "a", count: 1000),         // Long
            "😄",                                        // Unicode
            "Hello World",                               // With space
            "Hello\nWorld",                              // With newline
            "Hello!@#$%^&*()_+-=[]{}|;:,.<>?",          // Special chars
            "\0",                                        // Null char
            " ",                                         // Just space
            "\t\n\r",                                    // Whitespace
        ]
    }

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
        // Empty, single element variations, and a few elements
        var result: [[Element]] = [[]]
        for element in Element.fuzz.prefix(3) {
            result.append([element])
        }
        if Element.fuzz.count >= 2 {
            result.append(Array(Element.fuzz.prefix(2)))
        }
        if Element.fuzz.count >= 3 {
            result.append(Array(Element.fuzz.prefix(3)))
        }
        return result
    }

    public func mutate() -> [[Element]] {
        var mutations: [[Element]] = []

        // Remove element
        for i in indices {
            var copy = self
            copy.remove(at: i)
            mutations.append(copy)
        }

        // Add element
        for element in Element.fuzz.prefix(2) {
            mutations.append(self + [element])
            mutations.append([element] + self)
        }

        // Mutate individual elements
        for i in indices {
            for mutated in self[i].mutate().prefix(2) {
                var copy = self
                copy[i] = mutated
                mutations.append(copy)
            }
        }

        // Shuffle (if not empty)
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
