//
//  WhitespaceMutator.swift
//  PropertyTestingKit
//

import Dependencies
import Foundation

private let _whitespaceSeeds: [String] = [
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

private func _whitespaceMutate(_ value: String) -> [String] {
    var results: [String] = []
    results.append(" " + value)
    results.append(value + " ")
    results.append(" " + value + " ")
    results.append(value.replacingOccurrences(of: " ", with: "\t"))
    results.append(value.trimmingCharacters(in: .whitespaces))
    return results
}

private func _whitespaceGenerate(_ rng: inout FastRNG) -> String {
    _whitespaceSeeds.randomElement(using: &rng) ?? " "
}

/// Whitespace mutator for testing whitespace handling.
public let whitespaceMutator = Mutator<String>(
    seeds: _whitespaceSeeds,
    mutate: _whitespaceMutate,
    generate: _whitespaceGenerate
)
