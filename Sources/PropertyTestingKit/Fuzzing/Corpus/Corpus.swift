//
//  Corpus.swift
//  PropertyTestingKit
//
//  Storage and management of fuzzing inputs with coverage signatures.
//

import Dependencies
import Foundation

// MARK: - Corpus Coding Keys

/// A collection of test inputs with their coverage signatures.
///
/// The corpus tracks which inputs produce unique coverage and provides
/// minimization to keep only the essential inputs.
///
/// Uses inline bitmap storage with raw pointers for O(1) coverage checks,
/// avoiding the ARC overhead of Set<UInt32>.
///
/// Thread safety: Access is serialized by `FuzzStateMachine`, so this
/// class does not need its own synchronization.
public final class Corpus<each Input: Codable & Sendable>: @unchecked Sendable {

    /// All entries in the corpus.
    @usableFromInline
    var entries: [CorpusEntry<repeat each Input>]

    /// Bitmap storage - each bit represents one edge index.
    @usableFromInline
    let bitmapStorage: UnsafeMutablePointer<UInt64>

    /// Number of UInt64 words in the bitmap.
    @usableFromInline
    let bitmapWordCount: Int

    /// Total capacity in bits.
    @usableFromInline
    let bitmapCapacity: Int

    /// Number of set bits (cached for O(1) count access).
    @usableFromInline
    var bitmapCount: Int = 0

    init(entries: [CorpusEntry<repeat each Input>], coveredIndices: Set<UInt32>) {
        self.entries = entries

        // Initialize bitmap from the indices
        let capacity = SanCovCounters.isAvailable ? SanCovCounters.totalEdgeCount : 65536
        self.bitmapCapacity = capacity
        self.bitmapWordCount = (capacity + 63) / 64

        if bitmapWordCount > 0 {
            self.bitmapStorage = .allocate(capacity: bitmapWordCount)
            self.bitmapStorage.initialize(repeating: 0, count: bitmapWordCount)
        } else {
            self.bitmapStorage = .allocate(capacity: 1)
            self.bitmapStorage.initialize(to: 0)
        }

        // Populate from indices
        for index in coveredIndices {
            _ = bitmapInsert(index)
        }
    }

    init() {
        self.entries = []

        // Initialize bitmap eagerly
        let capacity = SanCovCounters.isAvailable ? SanCovCounters.totalEdgeCount : 65536
        self.bitmapCapacity = capacity
        self.bitmapWordCount = (capacity + 63) / 64

        if bitmapWordCount > 0 {
            self.bitmapStorage = .allocate(capacity: bitmapWordCount)
            self.bitmapStorage.initialize(repeating: 0, count: bitmapWordCount)
        } else {
            self.bitmapStorage = .allocate(capacity: 1)
            self.bitmapStorage.initialize(to: 0)
        }
    }

    deinit {
        bitmapStorage.deallocate()
    }

    // MARK: - Bitmap Operations (Static to avoid self retain/release)

    @inlinable
    static func bitmapContains(
        _ index: UInt32,
        storage: UnsafeMutablePointer<UInt64>,
        capacity: Int
    ) -> Bool {
        let i = Int(index)
        guard i < capacity else { return false }
        let wordIndex = i >> 6
        let bitIndex = i & 63
        return (storage[wordIndex] & (1 << bitIndex)) != 0
    }

    @inlinable
    static func bitmapInsert(
        _ index: UInt32,
        storage: UnsafeMutablePointer<UInt64>,
        capacity: Int
    ) -> Bool {
        let i = Int(index)
        guard i < capacity else { return false }
        let wordIndex = i >> 6
        let bitIndex = i & 63
        let mask: UInt64 = 1 << bitIndex
        let oldWord = storage[wordIndex]
        if (oldWord & mask) != 0 {
            return false
        }
        storage[wordIndex] = oldWord | mask
        return true
    }

    @inlinable
    static func bitmapHasUniqueCoverage(
        sparse: borrowing SparseCoverage,
        storage: UnsafeMutablePointer<UInt64>,
        capacity: Int
    ) -> Bool {
        for index in sparse.indices {
            if !bitmapContains(index, storage: storage, capacity: capacity) {
                return true
            }
        }
        return false
    }

    @inlinable
    static func bitmapMergeSparse(
        _ sparse: borrowing SparseCoverage,
        storage: UnsafeMutablePointer<UInt64>,
        capacity: Int
    ) -> Int {
        var insertedCount = 0
        for index in sparse.indices {
            if bitmapInsert(index, storage: storage, capacity: capacity) {
                insertedCount += 1
            }
        }
        return insertedCount
    }

    // MARK: - Instance Method Wrappers (for non-hot-path code)

    /// Instance wrapper for bitmapInsert - used by init and add() which are not in the hot path.
    @inline(__always)
    func bitmapInsert(_ index: UInt32) -> Bool {
        Self.bitmapInsert(index, storage: bitmapStorage, capacity: bitmapCapacity)
    }

    /// Instance wrapper for bitmapMergeSparse - used by add() which is not in the hot path.
    @inline(__always)
    func bitmapMergeSparse(_ sparse: borrowing SparseCoverage) {
        bitmapCount += Self.bitmapMergeSparse(sparse, storage: bitmapStorage, capacity: bitmapCapacity)
    }

    func bitmapExecutedIndices() -> Set<UInt32> {
        var result = Set<UInt32>()
        result.reserveCapacity(bitmapCount)
        for wordIndex in 0..<bitmapWordCount {
            var word = bitmapStorage[wordIndex]
            var bitIndex = 0
            while word != 0 {
                if (word & 1) != 0 {
                    result.insert(UInt32(wordIndex * 64 + bitIndex))
                }
                word >>= 1
                bitIndex += 1
            }
        }
        return result
    }

    // MARK: - Serialization

    /// Create a snapshot of the corpus state for encoding.
    func snapshot() -> CorpusSnapshot<repeat each Input> {
        return CorpusSnapshot(
            entries: entries,
            coveredIndices: bitmapExecutedIndices()
        )
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

    /// All covered edge indices.
    var coveredIndices: Set<UInt32> {
        bitmapExecutedIndices()
    }

    /// Number of covered edges.
    var coveredCount: Int {
        bitmapCount
    }

    // MARK: - Adding Entries

    /// Merge sparse coverage into the bitmap and add an entry unconditionally.
    ///
    /// Used by coverage strategies that have already determined the input is interesting.
    func mergeCoverageAndAdd(
        input: (repeat each Input),
        scheduleBytes: [UInt8]? = nil,
        sparse: SparseCoverage
    ) {
        bitmapMergeSparse(sparse)
        entries.append(CorpusEntry(
            input: repeat each input,
            scheduleBytes: scheduleBytes,
            sparseCoverage: sparse
        ))
    }

    /// Add an entry without merging coverage (caller already merged, e.g., newEdge strategy).
    func addEntry(
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

        bitmapMergeSparse(sparse)
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
        bitmapMergeSparse(sparse)
    }

    // MARK: - Minimization

    /// Minimize the corpus to the smallest set that covers all unique signatures.
    func minimized() -> CorpusSnapshot<repeat each Input> {
        guard !entries.isEmpty else { return snapshot() }

        var minimizedEntries: [CorpusEntry<repeat each Input>] = []
        var minimizedCoverage = Set<UInt32>()

        // Get all covered indices from the bitmap
        var uncovered: Set<UInt32> = bitmapExecutedIndices()

        // First, preserve ALL failure entries
        var remainingCoverage = entries.enumerated().map { ($0.offset, $0.element) }
        var indicesToRemove: [Int] = []

        for (i, (_, entry)) in remainingCoverage.enumerated() {
            if entry.entryType == .failure {
                minimizedEntries.append(entry)
                for index in entry.sparseCoverage.indices {
                    minimizedCoverage.insert(index)
                }
                entry.sparseCoverage.subtractIndices(from: &uncovered)
                indicesToRemove.append(i)
            }
        }

        for index in indicesToRemove.reversed() {
            remainingCoverage.remove(at: index)
        }

        // Greedy algorithm for remaining entries
        while !uncovered.isEmpty && !remainingCoverage.isEmpty {
            var bestIndex = 0
            var bestCoverageCount = 0

            for (i, (_, entry)) in remainingCoverage.enumerated() {
                let covers = entry.sparseCoverage.countIndicesIn(uncovered)
                if covers > bestCoverageCount {
                    bestCoverageCount = covers
                    bestIndex = i
                }
            }

            if bestCoverageCount == 0 {
                break
            }

            let (_, bestEntry) = remainingCoverage.remove(at: bestIndex)
            minimizedEntries.append(bestEntry)
            for index in bestEntry.sparseCoverage.indices {
                minimizedCoverage.insert(index)
            }

            bestEntry.sparseCoverage.subtractIndices(from: &uncovered)
        }

        return CorpusSnapshot(
            entries: minimizedEntries,
            coveredIndices: minimizedCoverage
        )
    }
}

// MARK: - Corpus Snapshot

/// A serializable snapshot of corpus state.
/// On disk this is a plain JSON array of entries: `[{input: ...}, ...]`
public struct CorpusSnapshot<each Input: Codable & Sendable>: Sendable, Codable {
    public let entries: [CorpusEntry<repeat each Input>]
    public let coveredIndices: Set<UInt32>

    public init(
        entries: consuming [CorpusEntry<repeat each Input>],
        coveredIndices: consuming Set<UInt32>
    ) {
        self.entries = entries
        self.coveredIndices = coveredIndices
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
        self.coveredIndices = []
    }
}

extension Corpus {
    /// Create a corpus from a snapshot.
    convenience init(from snapshot: CorpusSnapshot<repeat each Input>) {
        self.init(
            entries: snapshot.entries,
            coveredIndices: snapshot.coveredIndices
        )
    }
}
