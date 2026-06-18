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

//  Storage and management of fuzzing inputs with coverage signatures.
//

import Dependencies
import Foundation

// MARK: - Corpus Coding Keys

/// A collection of test inputs the scheduler chose to retain.
///
/// The corpus is the engine's input store: it holds the inputs a scheduler
/// admitted, each tagged with the coverage signature that was current when it
/// was retained (kept for cross-engine deduplication and serialization). The
/// *aggregate* covered-edge set is no longer the corpus's concern — that is
/// coverage-specific bookkeeping owned by the coverage probe.
///
/// Thread safety: Access is serialized by `FuzzStateMachine`, so this
/// class does not need its own synchronization.
public final class Corpus<each Input: Codable & Sendable>: @unchecked Sendable {

    /// All entries in the corpus.
    @usableFromInline
    var entries: [CorpusEntry<repeat each Input>]

    init(entries: [CorpusEntry<repeat each Input>]) {
        self.entries = entries
    }

    init() {
        self.entries = []
    }

    // MARK: - Serialization

    /// Create a snapshot of the corpus state for encoding.
    func snapshot() -> CorpusSnapshot<repeat each Input> {
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

    /// All signatures in the corpus.
    public var signatures: [SparseCoverage] {
        entries.map(\.sparseCoverage)
    }

    // MARK: - Adding Entries

    /// Add an entry unconditionally, tagging it with the coverage that was
    /// current when it was retained.
    ///
    /// Storage entry point for the engine once the scheduler said keep. Internal
    /// on purpose: strategies are pure judgement and never see the corpus.
    func mergeCoverageAndAdd(
        input: (repeat each Input),
        scheduleBytes: [UInt8]? = nil,
        sparse: SparseCoverage
    ) {
        entries.append(CorpusEntry(
            input: repeat each input,
            scheduleBytes: scheduleBytes,
            sparseCoverage: sparse
        ))
    }

    /// Add an entry if its coverage signature hash is new.
    ///
    /// Used by `mergeCorpusSnapshots` to deduplicate entries from parallel engines.
    ///
    /// - Returns: `true` if the entry was added, `false` if it was redundant.
    @discardableResult
    func addIfInteresting(
        input: borrowing (repeat each Input),
        scheduleBytes: [UInt8]? = nil,
        sparse: consuming SparseCoverage,
        signatureHashes: inout Set<Int>
    ) -> Bool {
        let hash = sparse.signatureHash
        guard !signatureHashes.contains(hash) else {
            return false
        }

        signatureHashes.insert(hash)
        entries.append(CorpusEntry(
            input: repeat each input,
            scheduleBytes: scheduleBytes,
            sparseCoverage: sparse
        ))
        return true
    }

    /// Add an entry unconditionally with metadata.
    func add(
        input: (repeat each Input),
        scheduleBytes: [UInt8]? = nil,
        sparse: SparseCoverage,
        entryType: CorpusEntryType = .coverage,
        failure: FailureInfo? = nil
    ) {
        let entry = CorpusEntry(
            input: repeat each input,
            scheduleBytes: scheduleBytes,
            sparseCoverage: sparse,
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
    convenience init(from snapshot: CorpusSnapshot<repeat each Input>) {
        self.init(entries: snapshot.entries)
    }
}
