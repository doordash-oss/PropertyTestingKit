//
//  URLMutator.swift
//  PropertyTestingKit
//

import Dependencies

struct URLMutator: Mutator, Sendable {
    @Dependency(\.random) private var random

    var seeds: [String] {
        [
            "https://example.com",
            "http://localhost:8080/path?query=value",
            "ftp://files.example.com/file.txt",
            "file:///etc/passwd",
            "javascript:alert(1)",
            "data:text/html,<h1>Hello</h1>",
            "//protocol-relative.com",
            "https://user:pass@example.com:8080/path",
            "https://example.com/../../../etc/passwd",
            "https://evil.com@good.com",
        ]
    }

    func mutate(_ value: String) -> [String] {
        var results: [String] = []
        results.append(value.replacingOccurrences(of: "https", with: "http"))
        results.append(value.replacingOccurrences(of: "http", with: "https"))
        results.append(value + "/../../../etc/passwd")
        results.append(value + "?<script>alert(1)</script>")
        results.append(value.replacingOccurrences(of: "/", with: "//"))
        results.append("javascript:" + value)
        return results
    }

    func generate() -> String {
        random { rng in
            let chars = Array("abcdefghijklmnopqrstuvwxyz")
            let protocols = ["https://", "http://", "ftp://"]
            let domain = String((0..<Int.random(in: 4...10, using: &rng)).map { _ in chars.randomElement(using: &rng)! })
            let tlds = ["com", "org", "net", "io"]
            let path = Bool.random(using: &rng) ? "/\(String((0..<5).map { _ in chars.randomElement(using: &rng)! }))" : ""
            return "\(protocols.randomElement(using: &rng)!)\(domain).\(tlds.randomElement(using: &rng)!)\(path)"
        }
    }
}
