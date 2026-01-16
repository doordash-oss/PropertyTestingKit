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

    // Character sets for random string generation - stored as ContiguousArray for better performance
    private static let alphanumericChars: ContiguousArray<Character> = ContiguousArray("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    private static let asciiPrintableChars: ContiguousArray<Character> = ContiguousArray(" !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~")
    private static let digitChars: ContiguousArray<Character> = ContiguousArray("0123456789")
    private static let emojiChars: ContiguousArray<Character> = ContiguousArray(["😀", "🎉", "🚀", "💡", "⚡", "🔥", "✨", "🌟"])
    private static let commonPatterns: ContiguousArray<String> = ["test", "foo", "bar", "hello", "world", "input", "data", "value"]

    /// Generates a random string from the given character set with minimal allocations.
    /// Uses a single random number to generate multiple character indices.
    @inline(__always)
    private static func randomString(
        length: Int,
        from chars: ContiguousArray<Character>,
        using rng: inout some RandomNumberGenerator
    ) -> String {
        guard length > 0 else { return "" }
        let charCount = chars.count

        // Pre-allocate the result string with known capacity
        var result = ""
        result.reserveCapacity(length)

        // Generate characters - use simple modulo on truncated bits to avoid overflow
        for _ in 0..<length {
            // Use truncatingIfNeeded to safely convert UInt64 to Int
            let randomValue = rng.next()
            let index = Int(truncatingIfNeeded: randomValue) & 0x7FFFFFFF % charCount
            result.append(chars[index])
        }

        return result
    }

    public static let defaultMutator: AnyMutator<String> = {
        @Dependency(\.random) var random
        let cachedRandom = random  // Cache to avoid repeated TaskLocal lookups
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
                cachedRandom { rng in
                    // Mix of strategies for interesting random string generation
                    let strategy = Int.random(in: 0..<10, using: &rng)
                    switch strategy {
                    case 0:
                        // Empty string
                        return ""
                    case 1:
                        // Single character
                        return randomString(length: 1, from: alphanumericChars, using: &rng)
                    case 2:
                        // Short alphanumeric (1-10 chars)
                        let length = Int.random(in: 1...10, using: &rng)
                        return randomString(length: length, from: alphanumericChars, using: &rng)
                    case 3:
                        // Medium alphanumeric (10-50 chars)
                        let length = Int.random(in: 10...50, using: &rng)
                        return randomString(length: length, from: alphanumericChars, using: &rng)
                    case 4:
                        // ASCII printable including special chars
                        let length = Int.random(in: 1...30, using: &rng)
                        return randomString(length: length, from: asciiPrintableChars, using: &rng)
                    case 5:
                        // Whitespace-heavy
                        let whitespace = [" ", "\t", "\n", "\r", "  ", "\t\t"]
                        let base = randomString(length: 5, from: alphanumericChars, using: &rng)
                        let wsIndex = Int.random(in: 0..<whitespace.count, using: &rng)
                        let ws = whitespace[wsIndex]
                        return Bool.random(using: &rng) ? ws + base : base + ws
                    case 6:
                        // Numeric string
                        let length = Int.random(in: 1...15, using: &rng)
                        return randomString(length: length, from: digitChars, using: &rng)
                    case 7:
                        // Unicode (emoji and non-ASCII)
                        let length = Int.random(in: 1...5, using: &rng)
                        return randomString(length: length, from: emojiChars, using: &rng)
                    case 8:
                        // Long string (reduced max from 500 to 100 for performance)
                        let length = Int.random(in: 50...100, using: &rng)
                        return randomString(length: length, from: alphanumericChars, using: &rng)
                    default:
                        // Common test patterns
                        let patternIndex = Int.random(in: 0..<commonPatterns.count, using: &rng)
                        let base = commonPatterns[patternIndex]
                        let suffix = Int.random(in: 0...999, using: &rng)
                        return "\(base)\(suffix)"
                    }
                }
            }
        )
    }()
}
