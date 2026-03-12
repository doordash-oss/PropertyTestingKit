//
//  String+MutatorProviding.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Dependencies
import Foundation

// Character sets for random string generation - stored as ContiguousArray for better performance
private let _alphanumericChars: ContiguousArray<Character> = ContiguousArray("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
private let _asciiPrintableChars: ContiguousArray<Character> = ContiguousArray(" !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~")
private let _digitChars: ContiguousArray<Character> = ContiguousArray("0123456789")
private let _emojiChars: ContiguousArray<Character> = ContiguousArray(["😀", "🎉", "🚀", "💡", "⚡", "🔥", "✨", "🌟"])
private let _commonPatterns: ContiguousArray<String> = ["test", "foo", "bar", "hello", "world", "input", "data", "value"]

// Static arrays for mutation to avoid per-call allocations
private let _prefixMutations: [String] = ["SECRET_", "PRIVATE_", "API_", "TOKEN_"]
private let _targetLengths: [Int] = [5, 8, 16, 32]
private let _whitespaceVariants: [String] = [" ", "\t", "\n", "\r", "  ", "\t\t"]

// Cache the seeds array to avoid regenerating the 1000-char string on each access
private let _stringSeeds: [String] = [
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

/// Generates a random string from the given character set with minimal allocations.
@inline(__always)
private func randomString(
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
        let randomValue = rng.next()
        let index = Int(truncatingIfNeeded: randomValue) & 0x7FFFFFFF % charCount
        result.append(chars[index])
    }

    return result
}

private func _stringMutate(_ value: String) -> [String] {
    // Pre-allocate with estimated capacity to avoid reallocations
    var mutations: [String] = []
    mutations.reserveCapacity(20)

    // Cache count once (O(n) operation for String)
    let valueCount = value.utf8.count  // Use utf8.count for O(1)
    let isEmpty = valueCount == 0

    // Length mutations
    if !isEmpty {
        mutations.append(String(value.dropLast()))
        mutations.append(String(value.dropFirst()))
    }
    mutations.append(value + "x")
    mutations.append("x" + value)

    // Case mutations - only if they would differ
    let upper = value.uppercased()
    if upper != value { mutations.append(upper) }
    let lower = value.lowercased()
    if lower != value { mutations.append(lower) }

    // Character mutations - only for non-empty strings
    if !isEmpty, let firstChar = value.first, firstChar != "X" {
        var result = value
        let idx = result.startIndex
        result.replaceSubrange(idx...idx, with: "X")
        mutations.append(result)
    }

    // Whitespace mutations
    mutations.append(value + " ")
    mutations.append(" " + value)
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    if trimmed != value { mutations.append(trimmed) }

    // Prefix mutations - use static array to avoid allocations
    for prefix in _prefixMutations {
        if !value.hasPrefix(prefix) {
            mutations.append(prefix + value)
        }
    }

    // Length-targeted mutations - use cached count
    for targetLen in _targetLengths {
        if valueCount < targetLen {
            mutations.append(value + String(repeating: "x", count: targetLen - valueCount))
        } else if valueCount > targetLen {
            mutations.append(String(value.prefix(targetLen)))
        }
    }

    return mutations
}

private func _stringGenerate(_ rng: inout FastRNG) -> String {
    // Mix of strategies for interesting random string generation
    let strategy = Int.random(in: 0..<10, using: &rng)
    switch strategy {
    case 0:
        // Empty string
        return ""
    case 1:
        // Single character
        return randomString(length: 1, from: _alphanumericChars, using: &rng)
    case 2:
        // Short alphanumeric (1-10 chars)
        let length = Int.random(in: 1...10, using: &rng)
        return randomString(length: length, from: _alphanumericChars, using: &rng)
    case 3:
        // Medium alphanumeric (10-50 chars)
        let length = Int.random(in: 10...50, using: &rng)
        return randomString(length: length, from: _alphanumericChars, using: &rng)
    case 4:
        // ASCII printable including special chars
        let length = Int.random(in: 1...30, using: &rng)
        return randomString(length: length, from: _asciiPrintableChars, using: &rng)
    case 5:
        // Whitespace-heavy
        let base = randomString(length: 5, from: _alphanumericChars, using: &rng)
        let wsIndex = Int.random(in: 0..<_whitespaceVariants.count, using: &rng)
        let ws = _whitespaceVariants[wsIndex]
        return Bool.random(using: &rng) ? ws + base : base + ws
    case 6:
        // Numeric string
        let length = Int.random(in: 1...15, using: &rng)
        return randomString(length: length, from: _digitChars, using: &rng)
    case 7:
        // Unicode (emoji and non-ASCII)
        let length = Int.random(in: 1...5, using: &rng)
        return randomString(length: length, from: _emojiChars, using: &rng)
    case 8:
        // Long string (reduced max from 500 to 100 for performance)
        let length = Int.random(in: 50...100, using: &rng)
        return randomString(length: length, from: _alphanumericChars, using: &rng)
    default:
        // Common test patterns
        let patternIndex = Int.random(in: 0..<_commonPatterns.count, using: &rng)
        let base = _commonPatterns[patternIndex]
        let suffix = Int.random(in: 0...999, using: &rng)
        return "\(base)\(suffix)"
    }
}

extension String: MutatorProviding {
    public static let defaultMutator = Mutator<String>(
        seeds: _stringSeeds,
        mutate: _stringMutate,
        generate: _stringGenerate
    )
}
