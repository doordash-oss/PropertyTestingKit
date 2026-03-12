//
//  URLMutator.swift
//  PropertyTestingKit
//

import Dependencies

private let _urlSeeds: [String] = [
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

private func _urlMutate(_ value: String) -> [String] {
    var results: [String] = []
    results.append(value.replacingOccurrences(of: "https", with: "http"))
    results.append(value.replacingOccurrences(of: "http", with: "https"))
    results.append(value + "/../../../etc/passwd")
    results.append(value + "?<script>alert(1)</script>")
    results.append(value.replacingOccurrences(of: "/", with: "//"))
    results.append("javascript:" + value)
    return results
}

private func _urlGenerate(_ rng: inout FastRNG) -> String {
    let chars = Array("abcdefghijklmnopqrstuvwxyz")
    let protocols = ["https://", "http://", "ftp://"]
    let domain = String((0..<Int.random(in: 4...10, using: &rng)).map { _ in chars.randomElement(using: &rng) ?? "a" })
    let tlds = ["com", "org", "net", "io"]
    let path = Bool.random(using: &rng) ? "/\(String((0..<5).map { _ in chars.randomElement(using: &rng) ?? "a" }))" : ""
    return "\(protocols.randomElement(using: &rng) ?? "https://")\(domain).\(tlds.randomElement(using: &rng) ?? "com")\(path)"
}

/// URL mutator for testing URL handling.
public let urlMutator = Mutator<String>(
    seeds: _urlSeeds,
    mutate: _urlMutate,
    generate: _urlGenerate
)
