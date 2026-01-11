//
//  UnicodeMutator.swift
//  PropertyTestingKit
//

import Dependencies

struct UnicodeMutator: Mutator, Sendable {
    @Dependency(\.random) private var random

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

    func generate() -> String {
        random { rng in seeds.randomElement(using: &rng) } ?? "😀"
    }
}
