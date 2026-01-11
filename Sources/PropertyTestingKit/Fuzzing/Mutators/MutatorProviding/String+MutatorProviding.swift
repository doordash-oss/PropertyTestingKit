//
//  String+MutatorProviding.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Dependencies

extension String: MutatorProviding {
    // Cache the seeds array to avoid regenerating the 1000-char string on each access
    private static let _cachedSeeds: [String] = [
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

    // Character sets for random string generation
    private static let alphanumericChars = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    private static let asciiPrintableChars = Array(" !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~")

    public static var defaultMutator: AnyMutator<String> {
        @Dependency(\.random) var random
        return AnyMutator(
            seeds: _cachedSeeds,
            mutate: { value in
                var mutations: [String] = []

                // Length mutations
                if !value.isEmpty {
                    mutations.append(String(value.dropLast()))
                    mutations.append(String(value.dropFirst()))
                }
                mutations.append(value + "x")
                mutations.append("x" + value)

                // Case mutations
                mutations.append(value.uppercased())
                mutations.append(value.lowercased())

                // Character mutations
                if !value.isEmpty {
                    var chars = Array(value)
                    chars[0] = "X"
                    mutations.append(String(chars))
                }

                // Whitespace mutations
                mutations.append(value + " ")
                mutations.append(" " + value)
                mutations.append(value.trimmingCharacters(in: .whitespaces))

                // Prefix mutations - try common prefixes
                for prefix in ["SECRET_", "PRIVATE_", "API_", "TOKEN_"] {
                    if !value.hasPrefix(prefix) {
                        mutations.append(prefix + value)
                    }
                }

                // Length-targeted mutations: try to hit common lengths
                for targetLen in [5, 8, 16, 32] {
                    if value.count < targetLen {
                        mutations.append(value + String(repeating: "x", count: targetLen - value.count))
                    } else if value.count > targetLen && targetLen > 0 {
                        mutations.append(String(value.prefix(targetLen)))
                    }
                }

                return mutations.filter { $0 != value }
            },
            generate: {
                random { rng in
                    // Mix of strategies for interesting random string generation
                    let strategy = Int.random(in: 0..<10, using: &rng)
                    switch strategy {
                    case 0:
                        // Empty string
                        return ""
                    case 1:
                        // Single character
                        return String(alphanumericChars.randomElement(using: &rng) ?? "a")
                    case 2:
                        // Short alphanumeric (1-10 chars)
                        let length = Int.random(in: 1...10, using: &rng)
                        return String((0..<length).map { _ in alphanumericChars.randomElement(using: &rng) ?? "a" })
                    case 3:
                        // Medium alphanumeric (10-50 chars)
                        let length = Int.random(in: 10...50, using: &rng)
                        return String((0..<length).map { _ in alphanumericChars.randomElement(using: &rng) ?? "a" })
                    case 4:
                        // ASCII printable including special chars
                        let length = Int.random(in: 1...30, using: &rng)
                        return String((0..<length).map { _ in asciiPrintableChars.randomElement(using: &rng) ?? "a" })
                    case 5:
                        // Whitespace-heavy
                        let whitespace = [" ", "\t", "\n", "\r", "  ", "\t\t"]
                        let base = String((0..<5).map { _ in alphanumericChars.randomElement(using: &rng) ?? "a" })
                        let ws = whitespace.randomElement(using: &rng) ?? " "
                        return Bool.random(using: &rng) ? ws + base : base + ws
                    case 6:
                        // Numeric string
                        let length = Int.random(in: 1...15, using: &rng)
                        let digits = Array("0123456789")
                        return String((0..<length).map { _ in digits.randomElement(using: &rng) ?? "0" })
                    case 7:
                        // Unicode (emoji and non-ASCII)
                        let emojis: [Character] = ["😀", "🎉", "🚀", "💡", "⚡", "🔥", "✨", "🌟"]
                        let length = Int.random(in: 1...5, using: &rng)
                        return String((0..<length).map { _ in emojis.randomElement(using: &rng) ?? "😀" })
                    case 8:
                        // Long string
                        let length = Int.random(in: 100...500, using: &rng)
                        return String((0..<length).map { _ in alphanumericChars.randomElement(using: &rng) ?? "a" })
                    default:
                        // Common test patterns
                        let patterns = ["test", "foo", "bar", "hello", "world", "input", "data", "value"]
                        let base = patterns.randomElement(using: &rng) ?? "test"
                        let suffix = Int.random(in: 0...999, using: &rng)
                        return "\(base)\(suffix)"
                    }
                }
            }
        )
    }
}
