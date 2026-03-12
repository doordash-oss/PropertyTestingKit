//
//  SQLInjectionMutator.swift
//  PropertyTestingKit
//

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
