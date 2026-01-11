//
//  WhitespaceMutator.swift
//  PropertyTestingKit
//

import Dependencies
import Foundation

struct WhitespaceMutator: Mutator, Sendable {
    @Dependency(\.random) private var random

    var seeds: [String] {
        [
            " ",
            "\t",
            "\n",
            "\r\n",
            "   ",
            "\t\t\t",
            " \t \n \r ",
            "\u{00A0}", // non-breaking space
            "\u{2003}", // em space
            "\u{200B}", // zero-width space
        ]
    }

    func mutate(_ value: String) -> [String] {
        var results: [String] = []
        results.append(" " + value)
        results.append(value + " ")
        results.append(" " + value + " ")
        results.append(value.replacingOccurrences(of: " ", with: "\t"))
        results.append(value.trimmingCharacters(in: .whitespaces))
        return results
    }

    func generate() -> String {
        random { rng in seeds.randomElement(using: &rng) } ?? " "
    }
}
