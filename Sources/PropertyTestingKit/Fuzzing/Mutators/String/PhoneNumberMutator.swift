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

private let _phoneNumberSeeds: [String] = [
    "+1-800-555-1234",
    "555-1234",
    "(555) 123-4567",
    "+44 20 7946 0958",
    "1-800-FLOWERS",
    "+1 (555) 123-4567 ext. 890",
    "911",
    "000-000-0000",
    "+0000000000000",
]

private func _phoneNumberMutate(_ value: String, _ rng: inout FastRNG) -> String {
    // Pick one applicable strategy at random and compute only that mutant.
    var strategies: [() -> String] = [
        { value.filter(\.isNumber) },   // add/remove formatting
        { "+1" + value },
        { "(" + value + ")" },
        { value + value },
    ]
    // Boundary mutations
    if !value.isEmpty {
        strategies.append { String(value.dropFirst()) }
        strategies.append { String(value.dropLast()) }
    }
    guard let strategy = strategies.randomElement(using: &rng) else { return value }
    return strategy()
}

private func _phoneNumberGenerate(_ rng: inout FastRNG) -> String {
    // Generate random phone number
    let digits = (0..<10).map { _ in String(Int.random(in: 0...9, using: &rng)) }.joined()
    let formats: [(String) -> String] = [
        { d in "+1-\(d.prefix(3))-\(d.dropFirst(3).prefix(3))-\(d.suffix(4))" },
        { d in "(\(d.prefix(3))) \(d.dropFirst(3).prefix(3))-\(d.suffix(4))" },
        { d in d },
    ]
    return (formats.randomElement(using: &rng) ?? { $0 })(digits)
}

/// Phone number mutator for testing phone number handling.
public let phoneNumberMutator = Mutator<String>(
    seeds: _phoneNumberSeeds,
    mutate: _phoneNumberMutate,
    generate: _phoneNumberGenerate
)
