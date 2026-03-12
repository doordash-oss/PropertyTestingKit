//
//  XSSMutator.swift
//  PropertyTestingKit
//

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

private func _xssMutate(_ value: String) -> [String] {
    var results: [String] = []
    results.append("<script>" + value + "</script>")
    results.append(value.replacingOccurrences(of: "<", with: "&lt;"))
    results.append(value.replacingOccurrences(of: ">", with: "&gt;"))
    results.append("<img src=x onerror=\"" + value + "\">")
    results.append(value.replacingOccurrences(of: "script", with: "SCRIPT"))
    return results
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
