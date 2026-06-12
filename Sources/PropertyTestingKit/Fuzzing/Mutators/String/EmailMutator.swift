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

private let _emailSeeds: [String] = [
    "test@example.com",
    "user+tag@domain.co.uk",
    "a@b.c",
    "very.long.email.address@subdomain.example.com",
    "@missing-local.com",
    "missing-at-sign.com",
    "spaces in@email.com",
    "unicode@ドメイン.jp",
    "\"quoted\"@example.com",
    "user@[127.0.0.1]",
]

private func _emailMutate(_ value: String, _ rng: inout FastRNG) -> String {
    var results: [String] = []
    results.append(value.replacingOccurrences(of: "@", with: "@@"))
    results.append(value.replacingOccurrences(of: ".", with: ".."))
    results.append(value + ".com")
    results.append("test@" + value)
    if let atIndex = value.firstIndex(of: "@") {
        results.append(String(value[..<atIndex]))
        results.append(String(value[value.index(after: atIndex)...]))
    }
    guard !results.isEmpty else { return value }
    return results[Int.random(in: 0..<results.count, using: &rng)]
}

private func _emailGenerate(_ rng: inout FastRNG) -> String {
    let chars = Array("abcdefghijklmnopqrstuvwxyz")
    let local = String((0..<Int.random(in: 3...10, using: &rng)).map { _ in chars.randomElement(using: &rng) ?? "a" })
    let domain = String((0..<Int.random(in: 3...8, using: &rng)).map { _ in chars.randomElement(using: &rng) ?? "a" })
    let tlds = ["com", "org", "net", "io", "co.uk"]
    return "\(local)@\(domain).\(tlds.randomElement(using: &rng) ?? "com")"
}

/// Email mutator for testing email address handling.
public let emailMutator = Mutator<String>(
    seeds: _emailSeeds,
    mutate: _emailMutate,
    generate: _emailGenerate
)
