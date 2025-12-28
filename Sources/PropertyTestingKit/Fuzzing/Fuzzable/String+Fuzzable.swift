//
//  String+Fuzzable.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

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
