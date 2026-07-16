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
import Foundation

// Static arrays at file scope
private let _characterSeeds: [Character] = ["a", "Z", "0", " ", "\n", "\t", "😄", "\0"]
private let _asciiPrintable: [Character] = Array(" !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~")
private let _lowercaseLetters: [Character] = Array("abcdefghijklmnopqrstuvwxyz")
private let _uppercaseLetters: [Character] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
private let _digits: [Character] = Array("0123456789")
private let _whitespace: [Character] = [" ", "\t", "\n", "\r"]
private let _emojis: [Character] = ["😀", "🎉", "🚀", "💡", "⚡", "🔥", "✨", "🌟"]

private func _characterMutate(_ value: Character, _ rng: inout FastRNG) -> Character {
    // Build applicable non-identity candidates, then pick uniformly — same
    // pattern as PortMutator / EmptyStringMutator. Neighborhood + class-local
    // steps explore near the input; class jumps reuse the generate pools so
    // mutation can reach beyond the 8 hard-coded seeds.
    var candidates: [Character] = []

    if let scalar = value.unicodeScalars.first {
        let code = scalar.value
        if code < 0x10FFFF, let up = Unicode.Scalar(code + 1) {
            candidates.append(Character(up))
        }
        if code > 0, let down = Unicode.Scalar(code - 1) {
            candidates.append(Character(down))
        }
    }

    let upperStr = String(value).uppercased()
    if upperStr.count == 1, let upper = upperStr.first, upper != value {
        candidates.append(upper)
    }
    let lowerStr = String(value).lowercased()
    if lowerStr.count == 1, let lower = lowerStr.first, lower != value {
        candidates.append(lower)
    }

    for pool in [_lowercaseLetters, _uppercaseLetters, _digits, _whitespace, _asciiPrintable, _emojis] {
        if let idx = pool.firstIndex(of: value) {
            if idx + 1 < pool.count { candidates.append(pool[idx + 1]) }
            if idx > 0 { candidates.append(pool[idx - 1]) }
        } else if let jump = pool.randomElement(using: &rng) {
            candidates.append(jump)
        }
    }

    for seed in _characterSeeds where seed != value {
        candidates.append(seed)
    }

    guard let mutant = candidates.filter({ $0 != value }).randomElement(using: &rng) else {
        return value
    }
    return mutant
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
