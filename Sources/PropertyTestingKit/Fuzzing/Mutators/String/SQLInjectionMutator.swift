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

private let _sqlInjectionSeeds: [String] = [
    "'; DROP TABLE users; --",
    "1' OR '1'='1",
    "1; SELECT * FROM users",
    "admin'--",
    "1 UNION SELECT * FROM passwords",
    "'; EXEC xp_cmdshell('dir'); --",
    "1' AND SLEEP(5)--",
    "' OR 1=1#",
    "admin') OR ('1'='1",
    "1'; WAITFOR DELAY '0:0:5'--",
]

private func _sqlInjectionMutate(_ value: String) -> [String] {
    var results: [String] = []
    results.append("'" + value)
    results.append(value + "'")
    results.append(value + "; DROP TABLE users; --")
    results.append(value + " OR 1=1")
    results.append(value.replacingOccurrences(of: "'", with: "''"))
    results.append(value + "/**/")
    return results
}

private func _sqlInjectionGenerate(_ rng: inout FastRNG) -> String {
    _sqlInjectionSeeds.randomElement(using: &rng) ?? "' OR 1=1--"
}

/// SQL injection mutator for testing SQL injection vulnerabilities.
public let sqlInjectionMutator = Mutator<String>(
    seeds: _sqlInjectionSeeds,
    mutate: _sqlInjectionMutate,
    generate: _sqlInjectionGenerate
)
