// Copyright 2026 DoorDash, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

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
