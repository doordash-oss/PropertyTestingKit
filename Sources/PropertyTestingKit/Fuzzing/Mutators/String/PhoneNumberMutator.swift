//
//  PhoneNumberMutator.swift
//  PropertyTestingKit
//

import Dependencies

struct PhoneNumberMutator: Mutator, Sendable {
    @Dependency(\.random) private var random

    var seeds: [String] {
        [
            "+1-800-555-1234",
            "555-1234",
            "(555) 123-4567",
            "+44 20 7946 0958",
            "1-800-FLOWERS",
            "+1 (555) 123-4567 ext. 890",
            "911",
            "000-000-0000",
            "+0000000000000",
        ]
    }

    func mutate(_ value: String) -> [String] {
        var results: [String] = []
        // Add/remove formatting
        results.append(value.filter(\.isNumber))
        results.append("+1" + value)
        results.append("(" + value + ")")
        // Boundary mutations
        if !value.isEmpty {
            results.append(String(value.dropFirst()))
            results.append(String(value.dropLast()))
        }
        results.append(value + value)
        return results
    }

    func generate() -> String {
        random { rng in
            // Generate random phone number
            let digits = (0..<10).map { _ in String(Int.random(in: 0...9, using: &rng)) }.joined()
            let formats = [
                { (d: String) in "+1-\(d.prefix(3))-\(d.dropFirst(3).prefix(3))-\(d.suffix(4))" },
                { (d: String) in "(\(d.prefix(3))) \(d.dropFirst(3).prefix(3))-\(d.suffix(4))" },
                { (d: String) in d },
            ]
            return formats.randomElement(using: &rng)!(digits)
        }
    }
}
