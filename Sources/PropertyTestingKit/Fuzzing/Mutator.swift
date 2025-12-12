//
//  Mutator.swift
//  PropertyTestingKit
//
//  Composable mutation strategies for fuzz testing.
//

import Foundation

// MARK: - Mutator Protocol

/// A type that can generate seed values and mutations for fuzzing.
///
/// Mutators provide an alternative to the `Fuzzable` protocol, allowing
/// users to compose domain-specific mutation strategies.
///
/// ## Usage
///
/// ```swift
/// // Use built-in mutators
/// try fuzz(using: String.mutators(.phoneNumbers, .emails)) { (input: String) in
///     validateInput(input)
/// }
///
/// // Combine multiple strategies
/// try fuzz(using: Int.mutators(.boundaries, .ports)) { (port: Int) in
///     testConnection(port: port)
/// }
/// ```
public protocol Mutator<Value>: Sendable {
    associatedtype Value: Sendable

    /// Seed values to start fuzzing with.
    var seeds: [Value] { get }

    /// Generate mutations of a value.
    func mutate(_ value: Value) -> [Value]
}

// MARK: - AnyMutator (Type Erasure)

/// A type-erased mutator.
public struct AnyMutator<Value: Sendable>: Mutator, Sendable {
    private let _seeds: @Sendable () -> [Value]
    private let _mutate: @Sendable (Value) -> [Value]

    public var seeds: [Value] { _seeds() }

    public func mutate(_ value: Value) -> [Value] {
        _mutate(value)
    }

    public init<M: Mutator>(_ mutator: M) where M.Value == Value {
        self._seeds = { mutator.seeds }
        self._mutate = { mutator.mutate($0) }
    }

    public init(seeds: [Value], mutate: @escaping @Sendable (Value) -> [Value]) {
        self._seeds = { seeds }
        self._mutate = mutate
    }
}

// MARK: - ComposedMutator

/// A mutator that combines multiple mutation strategies.
public struct ComposedMutator<Value: Sendable>: Mutator, Sendable {
    private let mutators: [AnyMutator<Value>]

    public var seeds: [Value] {
        mutators.flatMap(\.seeds)
    }

    public func mutate(_ value: Value) -> [Value] {
        mutators.flatMap { $0.mutate(value) }
    }

    public init(_ mutators: [AnyMutator<Value>]) {
        self.mutators = mutators
    }
}

// MARK: - DefaultMutator

/// A mutator that uses the type's `Fuzzable` conformance.
public struct DefaultMutator<Value: Fuzzable & Sendable>: Mutator, Sendable {
    public var seeds: [Value] { Value.fuzz }

    public func mutate(_ value: Value) -> [Value] {
        value.mutate()
    }

    public init() {}
}

// MARK: - SingleMutator

/// A mutator with a single strategy.
public struct SingleMutator<Value: Sendable>: Mutator, Sendable {
    public let seeds: [Value]
    private let _mutate: @Sendable (Value) -> [Value]

    public func mutate(_ value: Value) -> [Value] {
        _mutate(value)
    }

    public init(seeds: [Value], mutate: @escaping @Sendable (Value) -> [Value]) {
        self.seeds = seeds
        self._mutate = mutate
    }
}

// MARK: - String Mutators

/// Built-in string mutation strategies.
public enum StringMutationStrategy: Sendable {
    case phoneNumbers
    case emails
    case urls
    case sql
    case xss
    case unicode
    case whitespace
    case empty
    case boundaries
}

extension String {
    /// Create a composed mutator from multiple strategies.
    public static func mutators(_ strategies: StringMutationStrategy...) -> AnyMutator<String> {
        let mutators = strategies.map { strategy -> AnyMutator<String> in
            switch strategy {
            case .phoneNumbers:
                return AnyMutator(PhoneNumberMutator())
            case .emails:
                return AnyMutator(EmailMutator())
            case .urls:
                return AnyMutator(URLMutator())
            case .sql:
                return AnyMutator(SQLInjectionMutator())
            case .xss:
                return AnyMutator(XSSMutator())
            case .unicode:
                return AnyMutator(UnicodeMutator())
            case .whitespace:
                return AnyMutator(WhitespaceMutator())
            case .empty:
                return AnyMutator(EmptyStringMutator())
            case .boundaries:
                return AnyMutator(StringBoundaryMutator())
            }
        }
        return AnyMutator(ComposedMutator(mutators))
    }
}

// MARK: - String Mutator Implementations

struct PhoneNumberMutator: Mutator, Sendable {
    var seeds: [String] {
        [
            "+1-800-555-1234",
            "555-1234",
            "(555) 123-4567",
            "+44 20 7946 0958",
            "1-800-FLOWERS",
            "+1 (555) 123-4567 ext. 890",
            "911",
            "000-000-0000",
            "+0000000000000",
        ]
    }

    func mutate(_ value: String) -> [String] {
        var results: [String] = []
        // Add/remove formatting
        results.append(value.filter(\.isNumber))
        results.append("+1" + value)
        results.append("(" + value + ")")
        // Boundary mutations
        if !value.isEmpty {
            results.append(String(value.dropFirst()))
            results.append(String(value.dropLast()))
        }
        results.append(value + value)
        return results
    }
}

struct EmailMutator: Mutator, Sendable {
    var seeds: [String] {
        [
            "test@example.com",
            "user+tag@domain.co.uk",
            "a@b.c",
            "very.long.email.address@subdomain.example.com",
            "@missing-local.com",
            "missing-at-sign.com",
            "spaces in@email.com",
            "unicode@ドメイン.jp",
            "\"quoted\"@example.com",
            "user@[127.0.0.1]",
        ]
    }

    func mutate(_ value: String) -> [String] {
        var results: [String] = []
        results.append(value.replacingOccurrences(of: "@", with: "@@"))
        results.append(value.replacingOccurrences(of: ".", with: ".."))
        results.append(value + ".com")
        results.append("test@" + value)
        if let atIndex = value.firstIndex(of: "@") {
            results.append(String(value[..<atIndex]))
            results.append(String(value[value.index(after: atIndex)...]))
        }
        return results
    }
}

struct URLMutator: Mutator, Sendable {
    var seeds: [String] {
        [
            "https://example.com",
            "http://localhost:8080/path?query=value",
            "ftp://files.example.com/file.txt",
            "file:///etc/passwd",
            "javascript:alert(1)",
            "data:text/html,<h1>Hello</h1>",
            "//protocol-relative.com",
            "https://user:pass@example.com:8080/path",
            "https://example.com/../../../etc/passwd",
            "https://evil.com@good.com",
        ]
    }

    func mutate(_ value: String) -> [String] {
        var results: [String] = []
        results.append(value.replacingOccurrences(of: "https", with: "http"))
        results.append(value.replacingOccurrences(of: "http", with: "https"))
        results.append(value + "/../../../etc/passwd")
        results.append(value + "?<script>alert(1)</script>")
        results.append(value.replacingOccurrences(of: "/", with: "//"))
        results.append("javascript:" + value)
        return results
    }
}

struct SQLInjectionMutator: Mutator, Sendable {
    var seeds: [String] {
        [
            "'; DROP TABLE users; --",
            "1' OR '1'='1",
            "1; SELECT * FROM users",
            "admin'--",
            "1 UNION SELECT * FROM passwords",
            "'; EXEC xp_cmdshell('dir'); --",
            "1' AND SLEEP(5)--",
            "' OR 1=1#",
            "admin') OR ('1'='1",
            "1'; WAITFOR DELAY '0:0:5'--",
        ]
    }

    func mutate(_ value: String) -> [String] {
        var results: [String] = []
        results.append("'" + value)
        results.append(value + "'")
        results.append(value + "; DROP TABLE users; --")
        results.append(value + " OR 1=1")
        results.append(value.replacingOccurrences(of: "'", with: "''"))
        results.append(value + "/**/")
        return results
    }
}

struct XSSMutator: Mutator, Sendable {
    var seeds: [String] {
        [
            "<script>alert('XSS')</script>",
            "<img src=x onerror=alert(1)>",
            "<svg onload=alert(1)>",
            "javascript:alert(1)",
            "<body onload=alert(1)>",
            "'-alert(1)-'",
            "<iframe src='javascript:alert(1)'>",
            "<input onfocus=alert(1) autofocus>",
            "{{constructor.constructor('alert(1)')()}}",
            "<a href='javascript:alert(1)'>click</a>",
        ]
    }

    func mutate(_ value: String) -> [String] {
        var results: [String] = []
        results.append("<script>" + value + "</script>")
        results.append(value.replacingOccurrences(of: "<", with: "&lt;"))
        results.append(value.replacingOccurrences(of: ">", with: "&gt;"))
        results.append("<img src=x onerror=\"" + value + "\">")
        results.append(value.replacingOccurrences(of: "script", with: "SCRIPT"))
        return results
    }
}

struct UnicodeMutator: Mutator, Sendable {
    var seeds: [String] {
        [
            "Ω≈ç√∫",
            "😀🎉🚀",
            "‮reversed‬",
            "null\0char",
            "Ṫ̈ô̈ḟ̈ṷ̈",
            "田中太郎",
            "\u{FEFF}BOM",
            "🇺🇸🇬🇧🇯🇵",
            "a]︀", // variation selector
            "ﬁﬂ", // ligatures
        ]
    }

    func mutate(_ value: String) -> [String] {
        var results: [String] = []
        results.append(value.uppercased())
        results.append(value.lowercased())
        results.append(String(value.unicodeScalars.map { Character(UnicodeScalar($0.value + 1) ?? $0) }))
        results.append("\u{200B}" + value) // zero-width space
        results.append(value + "\u{FEFF}") // BOM
        return results
    }
}

struct WhitespaceMutator: Mutator, Sendable {
    var seeds: [String] {
        [
            " ",
            "\t",
            "\n",
            "\r\n",
            "   ",
            "\t\t\t",
            " \t \n \r ",
            "\u{00A0}", // non-breaking space
            "\u{2003}", // em space
            "\u{200B}", // zero-width space
        ]
    }

    func mutate(_ value: String) -> [String] {
        var results: [String] = []
        results.append(" " + value)
        results.append(value + " ")
        results.append(" " + value + " ")
        results.append(value.replacingOccurrences(of: " ", with: "\t"))
        results.append(value.trimmingCharacters(in: .whitespaces))
        return results
    }
}

struct EmptyStringMutator: Mutator, Sendable {
    var seeds: [String] {
        ["", " ", "\t", "\n", "\0"]
    }

    func mutate(_ value: String) -> [String] {
        var results: [String] = []
        if !value.isEmpty {
            results.append("")
            results.append(String(value.first!))
            results.append(String(value.last!))
        }
        results.append(value + value)
        return results
    }
}

struct StringBoundaryMutator: Mutator, Sendable {
    var seeds: [String] {
        [
            "",
            "a",
            String(repeating: "a", count: 255),
            String(repeating: "a", count: 256),
            String(repeating: "a", count: 65535),
            String(repeating: "🎉", count: 100),
        ]
    }

    func mutate(_ value: String) -> [String] {
        var results: [String] = []
        results.append(value + value)
        results.append(String(repeating: value, count: 10))
        if value.count > 1 {
            let mid = value.index(value.startIndex, offsetBy: value.count / 2)
            results.append(String(value[..<mid]))
        }
        return results
    }
}

// MARK: - Int Mutators

/// Built-in integer mutation strategies.
public enum IntMutationStrategy: Sendable {
    case boundaries
    case ports
    case httpStatusCodes
    case negative
    case powers
}

extension Int {
    /// Create a composed mutator from multiple strategies.
    public static func mutators(_ strategies: IntMutationStrategy...) -> AnyMutator<Int> {
        let mutators = strategies.map { strategy -> AnyMutator<Int> in
            switch strategy {
            case .boundaries:
                return AnyMutator(IntBoundaryMutator())
            case .ports:
                return AnyMutator(PortMutator())
            case .httpStatusCodes:
                return AnyMutator(HTTPStatusCodeMutator())
            case .negative:
                return AnyMutator(NegativeIntMutator())
            case .powers:
                return AnyMutator(PowerOfTwoMutator())
            }
        }
        return AnyMutator(ComposedMutator(mutators))
    }
}

// MARK: - Int Mutator Implementations

struct IntBoundaryMutator: Mutator, Sendable {
    var seeds: [Int] {
        [
            0, 1, -1,
            Int.max, Int.min,
            Int8.max.asInt, Int8.min.asInt,
            Int16.max.asInt, Int16.min.asInt,
            Int32.max.asInt, Int32.min.asInt,
            UInt8.max.asInt, UInt16.max.asInt,
        ]
    }

    func mutate(_ value: Int) -> [Int] {
        var results: [Int] = []
        if value < Int.max { results.append(value + 1) }
        if value > Int.min { results.append(value - 1) }
        if value != 0 && value > Int.min / 2 && value < Int.max / 2 {
            results.append(value * 2)
        }
        if value != 0 { results.append(value / 2) }
        results.append(-value)
        return results
    }
}

struct PortMutator: Mutator, Sendable {
    var seeds: [Int] {
        [
            0, 1, 21, 22, 23, 25, 53, 80, 110, 143,
            443, 465, 587, 993, 995, 3306, 5432, 6379,
            8080, 8443, 27017, 65535, 65536, -1,
        ]
    }

    func mutate(_ value: Int) -> [Int] {
        var results: [Int] = []
        if value < 65535 { results.append(value + 1) }
        if value > 0 { results.append(value - 1) }
        results.append(value % 65536)
        if value > 0 && value < 1024 { results.append(value + 1024) }
        return results
    }
}

struct HTTPStatusCodeMutator: Mutator, Sendable {
    var seeds: [Int] {
        [
            100, 101, 200, 201, 204, 301, 302, 304,
            400, 401, 403, 404, 405, 429, 500, 501,
            502, 503, 504, 0, -1, 999, 1000,
        ]
    }

    func mutate(_ value: Int) -> [Int] {
        var results: [Int] = []
        results.append(value + 100)
        results.append(value - 100)
        results.append(value % 600)
        return results.filter { $0 >= 0 }
    }
}

struct NegativeIntMutator: Mutator, Sendable {
    var seeds: [Int] {
        [-1, -2, -10, -100, -1000, Int.min, Int.min + 1]
    }

    func mutate(_ value: Int) -> [Int] {
        var results: [Int] = []
        results.append(-value)
        if value > Int.min { results.append(value - 1) }
        if value < -1 { results.append(value / 2) }
        return results
    }
}

struct PowerOfTwoMutator: Mutator, Sendable {
    var seeds: [Int] {
        [1, 2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536]
    }

    func mutate(_ value: Int) -> [Int] {
        var results: [Int] = []
        if value > 0 && value < Int.max / 2 { results.append(value * 2) }
        if value > 1 { results.append(value / 2) }
        if value < Int.max { results.append(value + 1) }
        if value > Int.min { results.append(value - 1) }
        return results
    }
}

// MARK: - Bool Mutator

extension Bool {
    /// Create a default bool mutator.
    public static func mutator() -> AnyMutator<Bool> {
        AnyMutator(BoolMutator())
    }
}

struct BoolMutator: Mutator, Sendable {
    var seeds: [Bool] { [true, false] }

    func mutate(_ value: Bool) -> [Bool] { [!value] }
}

// MARK: - Double Mutators

/// Built-in double mutation strategies.
public enum DoubleMutationStrategy: Sendable {
    case boundaries
    case special
    case percentages
}

extension Double {
    /// Create a composed mutator from multiple strategies.
    public static func mutators(_ strategies: DoubleMutationStrategy...) -> AnyMutator<Double> {
        let mutators = strategies.map { strategy -> AnyMutator<Double> in
            switch strategy {
            case .boundaries:
                return AnyMutator(DoubleBoundaryMutator())
            case .special:
                return AnyMutator(SpecialDoubleMutator())
            case .percentages:
                return AnyMutator(PercentageMutator())
            }
        }
        return AnyMutator(ComposedMutator(mutators))
    }
}

// MARK: - Double Mutator Implementations

struct DoubleBoundaryMutator: Mutator, Sendable {
    var seeds: [Double] {
        [
            0.0, 1.0, -1.0,
            Double.leastNormalMagnitude,
            Double.leastNonzeroMagnitude,
            Double.greatestFiniteMagnitude,
            -Double.greatestFiniteMagnitude,
        ]
    }

    func mutate(_ value: Double) -> [Double] {
        var results: [Double] = []
        results.append(value + 1)
        results.append(value - 1)
        results.append(value * 2)
        results.append(value / 2)
        results.append(-value)
        results.append(value + 0.1)
        results.append(value - 0.1)
        return results.filter(\.isFinite)
    }
}

struct SpecialDoubleMutator: Mutator, Sendable {
    var seeds: [Double] {
        [
            Double.nan,
            Double.infinity,
            -Double.infinity,
            Double.pi,
            Double.ulpOfOne,
            0.1 + 0.2, // classic floating point issue
        ]
    }

    func mutate(_ value: Double) -> [Double] {
        var results: [Double] = []
        if value.isFinite {
            results.append(value.nextUp)
            results.append(value.nextDown)
        }
        results.append(Double.nan)
        results.append(Double.infinity)
        return results
    }
}

struct PercentageMutator: Mutator, Sendable {
    var seeds: [Double] {
        [0.0, 0.5, 1.0, -0.1, 1.1, 0.01, 0.99, 0.001, 0.999]
    }

    func mutate(_ value: Double) -> [Double] {
        var results: [Double] = []
        results.append(min(1.0, value + 0.1))
        results.append(max(0.0, value - 0.1))
        results.append(1.0 - value)
        results.append(value * 0.5)
        return results
    }
}

// MARK: - Helper Extensions

private extension Int8 {
    var asInt: Int { Int(self) }
}

private extension Int16 {
    var asInt: Int { Int(self) }
}

private extension Int32 {
    var asInt: Int { Int(self) }
}

private extension UInt8 {
    var asInt: Int { Int(self) }
}

private extension UInt16 {
    var asInt: Int { Int(self) }
}
