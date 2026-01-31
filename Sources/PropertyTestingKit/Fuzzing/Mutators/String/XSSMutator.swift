//
//  XSSMutator.swift
//  PropertyTestingKit
//

import Dependencies

struct XSSMutator: Mutator, Sendable {
    @Dependency(\.fastRNG) private var fastRNG

    var seeds: [String] {
        [
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
    }

    func mutate(_ value: String) -> [String] {
        var results: [String] = []
        results.append("<script>" + value + "</script>")
        results.append(value.replacingOccurrences(of: "<", with: "&lt;"))
        results.append(value.replacingOccurrences(of: ">", with: "&gt;"))
        results.append("<img src=x onerror=\"" + value + "\">")
        results.append(value.replacingOccurrences(of: "script", with: "SCRIPT"))
        return results
    }

    func generate() -> String {
        var rng = fastRNG
        return seeds.randomElement(using: &rng) ?? "<script>alert(1)</script>"
    }
}
