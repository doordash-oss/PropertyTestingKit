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

private let _httpStatusCodeSeeds: [Int] = [
    100, 101, 200, 201, 204, 301, 302, 304,
    400, 401, 403, 404, 405, 429, 500, 501,
    502, 503, 504, 0, -1, 999, 1000,
]

private func _httpStatusCodeMutate(_ value: Int, _ rng: inout FastRNG) -> Int {
    var results: [Int] = []
    results.append(value + 100)
    results.append(value - 100)
    results.append(value % 600)
    results = results.filter { $0 >= 0 }
    guard !results.isEmpty else { return value }
    return results[Int.random(in: 0..<results.count, using: &rng)]
}

private func _httpStatusCodeGenerate(_ rng: inout FastRNG) -> Int {
    Int.random(in: 100...599, using: &rng)
}

/// HTTP status code mutator for testing HTTP response handling.
public let httpStatusCodeMutator = Mutator<Int>(
    seeds: _httpStatusCodeSeeds,
    mutate: _httpStatusCodeMutate,
    generate: _httpStatusCodeGenerate
)
