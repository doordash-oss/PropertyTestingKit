//
//  Character+MutatorProviding.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Dependencies
import Foundation

extension Character: MutatorProviding {
    private static let _seeds: [Character] = ["a", "Z", "0", " ", "\n", "\t", "😄", "\0"]

    private static let _alphanumeric: [Character] = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    private static let _asciiPrintable: [Character] = Array(" !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~")

    public static let defaultMutator: AnyMutator<Character> = {
        @Dependency(\.random) var random
        let cachedRandom = random  // Cache to avoid repeated TaskLocal lookups
        return AnyMutator(
            seeds: _seeds,
            mutate: { value in _seeds.filter { $0 != value } },
            generate: {
                cachedRandom { rng in
                    let strategy = Int.random(in: 0..<6, using: &rng)
                    switch strategy {
                    case 0:
                        // Lowercase letter
                        let letters = Array("abcdefghijklmnopqrstuvwxyz")
                        return letters.randomElement(using: &rng) ?? "a"
                    case 1:
                        // Uppercase letter
                        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
                        return letters.randomElement(using: &rng) ?? "A"
                    case 2:
                        // Digit
                        let digits = Array("0123456789")
                        return digits.randomElement(using: &rng) ?? "0"
                    case 3:
                        // Whitespace
                        let whitespace: [Character] = [" ", "\t", "\n", "\r"]
                        return whitespace.randomElement(using: &rng) ?? " "
                    case 4:
                        // ASCII printable
                        return _asciiPrintable.randomElement(using: &rng) ?? "a"
                    default:
                        // Emoji
                        let emojis: [Character] = ["😀", "🎉", "🚀", "💡", "⚡", "🔥", "✨", "🌟"]
                        return emojis.randomElement(using: &rng) ?? "😀"
                    }
                }
            }
        )
    }()
}
