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

private let _whitespaceSeeds: [String] = [
    " ",
    "\t",
    "\n",
    "\r\n",
    "   ",
    "\t\t\t",
    " \t \n \r ",
    "\u{00A0}", // non-breaking space
    "\u{2003}", // em space
    "\u{200B}", // zero-width space
]

private func _whitespaceMutate(_ value: String, _ rng: inout FastRNG) -> String {
    var results: [String] = []
    results.append(" " + value)
    results.append(value + " ")
    results.append(" " + value + " ")
    results.append(value.replacingOccurrences(of: " ", with: "\t"))
    results.append(value.trimmingCharacters(in: .whitespaces))
    guard !results.isEmpty else { return value }
    return results[Int.random(in: 0..<results.count, using: &rng)]
}

private func _whitespaceGenerate(_ rng: inout FastRNG) -> String {
    _whitespaceSeeds.randomElement(using: &rng) ?? " "
}

/// Whitespace mutator for testing whitespace handling.
public let whitespaceMutator = Mutator<String>(
    seeds: _whitespaceSeeds,
    mutate: _whitespaceMutate,
    generate: _whitespaceGenerate
)
