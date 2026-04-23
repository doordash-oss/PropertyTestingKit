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

//
//  Character+MutatorProviding.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Dependencies
import Foundation

// Static arrays at file scope
private let _characterSeeds: [Character] = ["a", "Z", "0", " ", "\n", "\t", "😄", "\0"]
private let _asciiPrintable: [Character] = Array(" !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~")
private let _lowercaseLetters: [Character] = Array("abcdefghijklmnopqrstuvwxyz")
private let _uppercaseLetters: [Character] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
private let _digits: [Character] = Array("0123456789")
private let _whitespace: [Character] = [" ", "\t", "\n", "\r"]
private let _emojis: [Character] = ["😀", "🎉", "🚀", "💡", "⚡", "🔥", "✨", "🌟"]

private func _characterMutate(_ value: Character) -> [Character] {
    _characterSeeds.filter { $0 != value }
}

private func _characterGenerate(_ rng: inout FastRNG) -> Character {
    let strategy = Int.random(in: 0..<6, using: &rng)
    switch strategy {
    case 0:
        // Lowercase letter
        return _lowercaseLetters.randomElement(using: &rng) ?? "a"
    case 1:
        // Uppercase letter
        return _uppercaseLetters.randomElement(using: &rng) ?? "A"
    case 2:
        // Digit
        return _digits.randomElement(using: &rng) ?? "0"
    case 3:
        // Whitespace
        return _whitespace.randomElement(using: &rng) ?? " "
    case 4:
        // ASCII printable
        return _asciiPrintable.randomElement(using: &rng) ?? "a"
    default:
        // Emoji
        return _emojis.randomElement(using: &rng) ?? "😀"
    }
}

extension Character: MutatorProviding {
    public static let defaultMutator = Mutator<Character>(
        seeds: _characterSeeds,
        mutate: _characterMutate,
        generate: _characterGenerate
    )
}
