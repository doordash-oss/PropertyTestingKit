//
//  EmailMutator.swift
//  PropertyTestingKit
//

import Dependencies

struct EmailMutator: Mutator, Sendable {
    @Dependency(\.random) private var random

    var seeds: [String] {
        [
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
    }

    func mutate(_ value: String) -> [String] {
        var results: [String] = []
        results.append(value.replacingOccurrences(of: "@", with: "@@"))
        results.append(value.replacingOccurrences(of: ".", with: ".."))
        results.append(value + ".com")
        results.append("test@" + value)
        if let atIndex = value.firstIndex(of: "@") {
            results.append(String(value[..<atIndex]))
            results.append(String(value[value.index(after: atIndex)...]))
        }
        return results
    }

    func generate() -> String {
        random { rng in
            let chars = Array("abcdefghijklmnopqrstuvwxyz")
            let local = String((0..<Int.random(in: 3...10, using: &rng)).map { _ in chars.randomElement(using: &rng)! })
            let domain = String((0..<Int.random(in: 3...8, using: &rng)).map { _ in chars.randomElement(using: &rng)! })
            let tlds = ["com", "org", "net", "io", "co.uk"]
            return "\(local)@\(domain).\(tlds.randomElement(using: &rng)!)"
        }
    }
}
