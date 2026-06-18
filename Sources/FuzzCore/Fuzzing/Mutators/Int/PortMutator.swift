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

private let _portSeeds: [Int] = [
    0, 1, 21, 22, 23, 25, 53, 80, 110, 143,
    443, 465, 587, 993, 995, 3306, 5432, 6379,
    8080, 8443, 27017, 65535, 65536, -1,
]

private func _portMutate(_ value: Int, _ rng: inout FastRNG) -> Int {
    // Build the applicable candidates, then pick uniformly among those that
    // actually change `value`. `value % 65536` is the identity for any port in
    // [0, 65536) — exactly the well-known ports — so filtering is what keeps the
    // mutant productive.
    var candidates: [Int] = []
    if value < 65535 { candidates.append(value + 1) }
    if value > 0 { candidates.append(value - 1) }
    candidates.append(value % 65536)
    if value > 0 && value < 1024 { candidates.append(value + 1024) }
    guard let pick = candidates.filter({ $0 != value }).randomElement(using: &rng) else { return value }
    return pick
}

private func _portGenerate(_ rng: inout FastRNG) -> Int {
    Int.random(in: 0...65535, using: &rng)
}

/// Port number mutator for testing network port handling.
public let portMutator = Mutator<Int>(
    seeds: _portSeeds,
    mutate: _portMutate,
    generate: _portGenerate
)
