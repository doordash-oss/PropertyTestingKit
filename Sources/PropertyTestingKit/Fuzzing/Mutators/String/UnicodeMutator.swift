// Copyright 2026 DoorDash, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

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

private func _unicodeMutate(_ value: String, _ rng: inout FastRNG) -> String {
    // Pick one strategy at random and compute only that mutant.
    switch Int.random(in: 0..<5, using: &rng) {
    case 0: return value.uppercased()
    case 1: return value.lowercased()
    case 2: return String(value.unicodeScalars.map { Character(UnicodeScalar($0.value + 1) ?? $0) })
    case 3: return "\u{200B}" + value // zero-width space
    default: return value + "\u{FEFF}" // BOM
    }
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
