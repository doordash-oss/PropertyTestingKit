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

private let _xssSeeds: [String] = [
    "<script>alert('XSS')</script>",
    "<img src=x onerror=alert(1)>",
    "<svg onload=alert(1)>",
    "javascript:alert(1)",
    "<body onload=alert(1)>",
    "'-alert(1)-'",
    "<iframe src='javascript:alert(1)'>",
    "<input onfocus=alert(1) autofocus>",
    "{{constructor.constructor('alert(1)')()}}",
    "<a href='javascript:alert(1)'>click</a>",
]

private func _xssMutate(_ value: String, _ rng: inout FastRNG) -> String {
    var results: [String] = []
    results.append("<script>" + value + "</script>")
    results.append(value.replacingOccurrences(of: "<", with: "&lt;"))
    results.append(value.replacingOccurrences(of: ">", with: "&gt;"))
    results.append("<img src=x onerror=\"" + value + "\">")
    results.append(value.replacingOccurrences(of: "script", with: "SCRIPT"))
    guard !results.isEmpty else { return value }
    return results[Int.random(in: 0..<results.count, using: &rng)]
}

private func _xssGenerate(_ rng: inout FastRNG) -> String {
    _xssSeeds.randomElement(using: &rng) ?? "<script>alert(1)</script>"
}

/// XSS mutator for testing cross-site scripting vulnerabilities.
public let xssMutator = Mutator<String>(
    seeds: _xssSeeds,
    mutate: _xssMutate,
    generate: _xssGenerate
)
