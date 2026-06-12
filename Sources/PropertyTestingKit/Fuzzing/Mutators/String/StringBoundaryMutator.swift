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

private let _stringBoundarySeeds: [String] = [
    "",
    "a",
    String(repeating: "a", count: 255),
    String(repeating: "a", count: 256),
    String(repeating: "a", count: 65535),
    String(repeating: "🎉", count: 100),
]

private func _stringBoundaryMutate(_ value: String, _ rng: inout FastRNG) -> String {
    var results: [String] = []
    results.append(value + value)
    results.append(String(repeating: value, count: 10))
    if value.count > 1 {
        let mid = value.index(value.startIndex, offsetBy: value.count / 2)
        results.append(String(value[..<mid]))
    }
    guard !results.isEmpty else { return value }
    return results[Int.random(in: 0..<results.count, using: &rng)]
}

private func _stringBoundaryGenerate(_ rng: inout FastRNG) -> String {
    let lengths = [0, 1, 10, 100, 255, 256, 1000]
    let length = lengths.randomElement(using: &rng) ?? 10
    let chars = Array("abcdefghijklmnopqrstuvwxyz")
    return String((0..<length).map { _ in chars.randomElement(using: &rng) ?? "a" })
}

/// String boundary mutator for testing string length boundaries.
public let stringBoundaryMutator = Mutator<String>(
    seeds: _stringBoundarySeeds,
    mutate: _stringBoundaryMutate,
    generate: _stringBoundaryGenerate
)
