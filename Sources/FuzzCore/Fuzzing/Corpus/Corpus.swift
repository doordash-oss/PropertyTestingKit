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

//  Storage and serialization of the inputs a scheduler chose to retain.
//

import Dependencies
import Foundation

// MARK: - Corpus Coding Keys

/// A collection of test inputs the scheduler chose to retain.
///
/// The corpus is the engine's input store: it holds the inputs a scheduler
/// retained (read back from the scheduler's working set at run-end) plus any
/// entries plugins submitted during the run (e.g. tagged failures). It makes no
/// retention decision and carries no coverage: interestingness is the
/// scheduler's call, and the aggregate covered-edge set is the coverage probe's.
///
/// Thread safety: Access is serialized by `FuzzStateMachine`, so this
/// class does not need its own synchronization.
public final class Corpus<each Input: Codable & Sendable>: @unchecked Sendable {

    /// All entries in the corpus.
    public internal(set) var entries: [CorpusEntry<repeat each Input>]

    public init(entries: [CorpusEntry<repeat each Input>]) {
        self.entries = entries
    }

    public init() {
        self.entries = []
    }

    // MARK: - Serialization

    /// Create a snapshot of the corpus state for encoding.
    public func snapshot() -> CorpusSnapshot<repeat each Input> {
        return CorpusSnapshot(entries: entries)
    }

    /// Number of entries in the corpus.
    public var count: Int { entries.count }

    /// Whether the corpus is empty.
    public var isEmpty: Bool { entries.isEmpty }

    /// All inputs in the corpus.
    public var inputs: [(repeat each Input)] {
        entries.map(\.input)
    }

    // MARK: - Adding Entries

    /// Add an entry unconditionally with metadata.
    ///
    /// The engine's storage entry point: it appends the scheduler's retained
    /// inputs at run-end, and plugins submit tagged entries (e.g. failures)
    /// during the run. Membership is the scheduler's (or a plugin's) decision —
    /// the corpus no longer judges interestingness or tags entries with coverage.
    public func add(
        input: (repeat each Input),
        scheduleBytes: [UInt8]? = nil,
        entryType: CorpusEntryType = .coverage,
        failure: FailureInfo? = nil
    ) {
        let entry = CorpusEntry(
            input: repeat each input,
            scheduleBytes: scheduleBytes,
            entryType: entryType,
            failure: failure
        )
        entries.append(entry)
    }
}

// MARK: - Corpus Snapshot

/// A serializable snapshot of corpus state.
/// On disk this is a plain JSON array of entries: `[{input: ...}, ...]`
public struct CorpusSnapshot<each Input: Codable & Sendable>: Sendable, Codable {
    public let entries: [CorpusEntry<repeat each Input>]

    public init(
        entries: consuming [CorpusEntry<repeat each Input>]
    ) {
        self.entries = entries
    }

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(entries)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.entries = try container.decode([CorpusEntry<repeat each Input>].self)
    }
}

extension Corpus {
    /// Create a corpus from a snapshot.
    public convenience init(from snapshot: CorpusSnapshot<repeat each Input>) {
        self.init(entries: snapshot.entries)
    }
}
