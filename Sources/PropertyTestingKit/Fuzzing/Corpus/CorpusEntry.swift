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

import Foundation
import Dependencies

/// Key used to signal the decoder that schedule bytes are the first element.
public extension CodingUserInfoKey {
    static let scheduleFuzzing = CodingUserInfoKey(rawValue: "scheduleFuzzing")!
}

/// A single entry in the corpus: an input and its coverage data.
public struct CorpusEntry<each Input: Codable & Sendable>: Sendable, Codable {
    /// The test input.
    public let input: (repeat each Input)

    /// Schedule bytes controlling task interleaving order.
    /// Non-nil when schedule fuzzing is enabled.
    public let scheduleBytes: [UInt8]?

    /// The sparse coverage data.
    public let sparseCoverage: SparseCoverage

    /// The reason this entry was added to the corpus.
    public let entryType: CorpusEntryType

    // TODO: Move failureInfo into corpus entry type
    /// Failure information if this entry caused a test failure.
    public let failure: FailureInfo?

    public init(
        input: repeat each Input,
        scheduleBytes: [UInt8]? = nil,
        sparseCoverage: consuming SparseCoverage,
        entryType: CorpusEntryType = .coverage,
        failure: FailureInfo? = nil
    ) {
        self.input = (repeat each input)
        self.scheduleBytes = scheduleBytes
        self.sparseCoverage = sparseCoverage
        self.entryType = entryType
        self.failure = failure
    }

    /// Encodes as a plain JSON array.
    /// Without schedule bytes: `[42]` or `["hello", 3]`
    /// With schedule bytes: `[[1,2,3], 42]` (schedule bytes prepended)
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        if let scheduleBytes {
            try container.encode(scheduleBytes)
        }
        (repeat try container.encode(each input))
    }

    /// Decodes from a plain JSON array of inputs.
    /// When `decoder.userInfo[.scheduleFuzzing]` is `true`, reads the first
    /// element as `[UInt8]` schedule bytes before reading user inputs.
    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        if let flag = decoder.userInfo[.scheduleFuzzing] as? Bool, flag {
            self.scheduleBytes = try container.decode([UInt8].self)
        } else {
            self.scheduleBytes = nil
        }
        self.input = (repeat try container.decode((each Input).self))
        self.sparseCoverage = SparseCoverage()
        self.entryType = .coverage
        self.failure = nil
    }
}
