//
//  SQLInjectionMutator.swift
//  PropertyTestingKit
//

import Dependencies

struct SQLInjectionMutator: Mutator, Sendable {
    @Dependency(\.random) private var random

    var seeds: [String] {
        [
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
    }

    func mutate(_ value: String) -> [String] {
        var results: [String] = []
        results.append("'" + value)
        results.append(value + "'")
        results.append(value + "; DROP TABLE users; --")
        results.append(value + " OR 1=1")
        results.append(value.replacingOccurrences(of: "'", with: "''"))
        results.append(value + "/**/")
        return results
    }

    func generate() -> String {
        random { rng in seeds.randomElement(using: &rng) } ?? "' OR 1=1--"
    }
}
