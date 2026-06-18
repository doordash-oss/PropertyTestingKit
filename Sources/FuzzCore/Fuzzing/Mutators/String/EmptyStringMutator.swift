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

private let _emptyStringSeeds: [String] = ["", " ", "\t", "\n", "\0"]

private func _emptyStringMutate(_ value: String, _ rng: inout FastRNG) -> String {
    // Build the applicable candidates, then pick uniformly among those that
    // actually change `value`. For a single-character input both `String(first)`
    // and `String(last)` equal the input, so filtering keeps the mutant
    // productive. The empty string pins the doubling strategy too (`"" + ""` is
    // `""`), so it escapes to a non-empty whitespace seed — an on-theme mutation
    // for an empty/whitespace mutator rather than a wasted identity.
    var candidates: [String] = [value + value]
    if value.isEmpty {
        candidates.append(contentsOf: _emptyStringSeeds)
    } else {
        candidates.append("")
        if let first = value.first { candidates.append(String(first)) }
        if let last = value.last { candidates.append(String(last)) }
    }
    guard let pick = candidates.filter({ $0 != value }).randomElement(using: &rng) else { return value }
    return pick
}

private func _emptyStringGenerate(_ rng: inout FastRNG) -> String {
    _emptyStringSeeds.randomElement(using: &rng) ?? ""
}

/// Empty string mutator for testing empty/whitespace string handling.
public let emptyStringMutator = Mutator<String>(
    seeds: _emptyStringSeeds,
    mutate: _emptyStringMutate,
    generate: _emptyStringGenerate
)
