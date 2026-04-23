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

private func _emptyStringMutate(_ value: String) -> [String] {
    var results: [String] = []
    if !value.isEmpty {
        results.append("")
        if let first = value.first {
            results.append(String(first))
        }
        if let last = value.last {
            results.append(String(last))
        }
    }
    results.append(value + value)
    return results
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
