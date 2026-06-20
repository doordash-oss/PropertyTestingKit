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

//  The corpus: a serializable snapshot of the inputs a scheduler chose to retain.
//
//  There is no mutable corpus type. The engine holds no corpus during a run; it
//  materializes this snapshot once, at run-end, from the scheduler's retained set
//  (`AnyScheduler.snapshot()`). The corpus makes no retention decision and carries
//  no coverage — interestingness is the scheduler's call, and the aggregate
//  covered-edge set is the coverage probe's.
//

import Foundation

/// A serializable snapshot of the retained corpus.
/// On disk this is a plain JSON array of entries: `[[42], ["hello", 3]]`.
public struct CorpusSnapshot<each Input: Codable & Sendable>: Sendable, Codable {
    public let entries: [CorpusEntry<repeat each Input>]

    public init(
        entries: consuming [CorpusEntry<repeat each Input>]
    ) {
        self.entries = entries
    }

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }

    /// All inputs in the corpus.
    public var inputs: [(repeat each Input)] {
        entries.map(\.input)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(entries)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.entries = try container.decode([CorpusEntry<repeat each Input>].self)
    }
}
