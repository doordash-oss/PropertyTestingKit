//
//  CorpusEntry.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Foundation
import Dependencies

/// A single entry in the corpus: an input and its coverage data.
public struct CorpusEntry<each Input: Codable & Sendable>: Sendable, Codable {
    /// The test input.
    public let input: (repeat each Input)

    /// The sparse coverage data.
    public let sparseCoverage: SparseCoverage

    /// The reason this entry was added to the corpus.
    public let entryType: CorpusEntryType

    // TODO: Move failureInfo into corpus entry type
    /// Failure information if this entry caused a test failure.
    public let failure: FailureInfo?

    public init(
        input: repeat each Input,
        sparseCoverage: consuming SparseCoverage,
        entryType: CorpusEntryType = .coverage,
        failure: FailureInfo? = nil
    ) {
        self.input = (repeat each input)
        self.sparseCoverage = sparseCoverage
        self.entryType = entryType
        self.failure = failure
    }

    /// Encodes as a plain JSON array of inputs: `[42]` or `["hello", 3]`
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        (repeat try container.encode(each input))
    }

    /// Decodes from a plain JSON array of inputs: `[42]` or `["hello", 3]`
    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        self.input = (repeat try container.decode((each Input).self))
        self.sparseCoverage = SparseCoverage()
        self.entryType = .coverage
        self.failure = nil
    }
}
