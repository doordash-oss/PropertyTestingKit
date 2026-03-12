//
//  UnicodeMutator.swift
//  PropertyTestingKit
//

import Dependencies

private let _unicodeSeeds: [String] = [
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

private func _unicodeMutate(_ value: String) -> [String] {
    var results: [String] = []
    results.append(value.uppercased())
    results.append(value.lowercased())
    results.append(String(value.unicodeScalars.map { Character(UnicodeScalar($0.value + 1) ?? $0) }))
    results.append("\u{200B}" + value) // zero-width space
    results.append(value + "\u{FEFF}") // BOM
    return results
}

private func _unicodeGenerate(_ rng: inout FastRNG) -> String {
    _unicodeSeeds.randomElement(using: &rng) ?? "😀"
}

/// Unicode mutator for testing Unicode handling.
public let unicodeMutator = Mutator<String>(
    seeds: _unicodeSeeds,
    mutate: _unicodeMutate,
    generate: _unicodeGenerate
)
