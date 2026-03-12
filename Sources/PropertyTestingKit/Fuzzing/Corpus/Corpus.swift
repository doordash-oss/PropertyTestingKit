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

    /// When true, addIfInteresting always returns true (for testing without coverage).
    @usableFromInline
    let alwaysInteresting: Bool

    /// Set of coverage signature hashes for detecting unique code paths.
    /// A new input is interesting if its signature hash is not in this set,
    /// even if all its edges have been seen before (different code path).
    @usableFromInline
    var signatureHashes: Set<Int>

    init(entries: [CorpusEntry<repeat each Input>], coveredIndices: Set<UInt32>, alwaysInteresting: Bool = false) {
        self.entries = entries
        self.alwaysInteresting = alwaysInteresting
        self.signatureHashes = Set(entries.map { $0.sparseCoverage.signatureHash })

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

    init(alwaysInteresting: Bool = false) {
        self.entries = []
        self.alwaysInteresting = alwaysInteresting
        self.signatureHashes = []

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

    /// Check if raw coverage data contains unique indices (not yet in bitmap).
    /// This avoids allocation when coverage is not interesting.
    @inlinable
    static func hasUniqueCoverageRaw(
        ptr: UnsafePointer<UInt32>?,
        count: Int,
        storage: UnsafeMutablePointer<UInt64>,
        capacity: Int
    ) -> Bool {
        guard let ptr = ptr, count > 0 else { return false }
        for i in 0..<count {
            if !bitmapContains(ptr[i], storage: storage, capacity: capacity) {
                return true
            }
        }
        return false
    }

    /// Merge raw coverage data into bitmap.
    /// Returns the number of new indices added.
    @inlinable
    static func mergeRawCoverage(
        ptr: UnsafePointer<UInt32>,
        count: Int,
        storage: UnsafeMutablePointer<UInt64>,
        capacity: Int
    ) -> Int {
        var insertedCount = 0
        for i in 0..<count {
            if bitmapInsert(ptr[i], storage: storage, capacity: capacity) {
                insertedCount += 1
            }
        }
        return insertedCount
    }

    /// Compute signature hash from raw coverage data.
    /// Matches SparseCoverage.signatureHash algorithm.
    @inlinable
    static func computeSignatureHashRaw(ptr: UnsafePointer<UInt32>?, count: Int) -> Int {
        guard let ptr = ptr, count > 0 else { return 0 }

        // Golden ratio primes for mixing (as signed Int using bitPattern)
        let indexPrime = Int(bitPattern: 0x9e3779b97f4a7c15 as UInt)
        let countPrime = Int(bitPattern: 0x517cc1b727220a95 as UInt)

        var hash = 0
        for i in 0..<count {
            let mixed = Int(ptr[i]) &* indexPrime
            hash ^= mixed
        }
        hash ^= count &* countPrime
        return hash
    }

    /// Add an entry if raw coverage data represents a unique code path.
    /// This is the fast path that avoids SparseCoverage allocation when not interesting.
    ///
    /// - Returns: `true` if the entry was added, `false` if it was redundant.
    @discardableResult
    @inlinable
    func addIfInterestingRaw(
        input: borrowing (repeat each Input),
        ptr: UnsafePointer<UInt32>?,
        count: Int
    ) -> Bool {
        // Cache instance properties to avoid repeated self access (ARC overhead)
        let dominated = alwaysInteresting
        let storage = bitmapStorage
        let capacity = bitmapCapacity

        // Handle empty coverage
        guard let ptr = ptr, count > 0 else {
            // Edge case: alwaysInteresting but no coverage - add empty entry
            if dominated {
                entries.append(CorpusEntry(
                    input: repeat each input,
                    sparseCoverage: SparseCoverage()
                ))
                return true
            }
            return false
        }

        // Compute signature hash from raw data
        let hash = Self.computeSignatureHashRaw(ptr: ptr, count: count)

        // Fast path: check if signature is new
        guard dominated || !signatureHashes.contains(hash) else {
            return false
        }

        // Merge into bitmap
        bitmapCount += Self.mergeRawCoverage(ptr: ptr, count: count, storage: storage, capacity: capacity)

        // Track signature hash
        signatureHashes.insert(hash)

        // Now allocate the array (only when interesting)
        let indices = Array(UnsafeBufferPointer(start: ptr, count: count))
        let sparse = SparseCoverage(indices: indices)

        entries.append(CorpusEntry(
            input: repeat each input,
            sparseCoverage: sparse
        ))
        return true
    }

    /// Add an entry using signature hash checking for uniqueness.
    /// This is the fastest path - computes signature hash in C without allocation.
    /// Only allocates SparseCoverage when the signature is interesting.
    ///
    /// - Parameters:
    ///   - input: The test input.
    ///   - context: The measurement context to read coverage from.
    ///   - coverageClient: The coverage counters client.
    /// - Returns: `true` if the entry was added, `false` if it was redundant.
    @discardableResult
    func addIfInterestingWithBitmapMerge(
        input: borrowing (repeat each Input),
        context: SanCovCounters.MeasurementContext,
        coverageClient: CoverageCountersClient
    ) -> Bool {
        // alwaysInteresting mode: add everything
        if alwaysInteresting {
            // Get sparse coverage for the entry
            if let sparse = try? coverageClient.snapshotCoveredArraysWithContext(context) {
                bitmapMergeSparse(sparse)
                signatureHashes.insert(sparse.signatureHash)
                entries.append(CorpusEntry(
                    input: repeat each input,
                    sparseCoverage: sparse
                ))
            } else {
                entries.append(CorpusEntry(
                    input: repeat each input,
                    sparseCoverage: SparseCoverage()
                ))
            }
            return true
        }

        // Fast path: compute signature hash in C without allocation
        let hash = coverageClient.computeSignatureHash(context)

        // Check if this is a new code path (signature hash not seen before)
        guard !signatureHashes.contains(hash) else {
            return false
        }

        // New code path found - snapshot coverage and add entry
        guard let sparse = try? coverageClient.snapshotCoveredArraysWithContext(context) else {
            return false
        }

        // Merge coverage into bitmap and track signature
        bitmapCount += Self.bitmapMergeSparse(sparse, storage: bitmapStorage, capacity: bitmapCapacity)
        signatureHashes.insert(hash)

        entries.append(CorpusEntry(
            input: repeat each input,
            sparseCoverage: sparse
        ))

        return true
    }

    /// Add an entry if it represents a unique code path.
    ///
    /// An input is interesting if its coverage signature hash hasn't been seen before,
    /// indicating a different code path even if all edges were previously covered.
    ///
    /// - Returns: `true` if the entry was added, `false` if it was redundant.
    @discardableResult
    @inlinable
    func addIfInteresting(
        input: borrowing (repeat each Input),
        sparse: consuming SparseCoverage
    ) -> Bool {
        // alwaysInteresting mode: add everything (for testing without coverage)
        guard !alwaysInteresting else {
            let storage = bitmapStorage
            let capacity = bitmapCapacity
            bitmapCount += Self.bitmapMergeSparse(sparse, storage: storage, capacity: capacity)
            signatureHashes.insert(sparse.signatureHash)
            entries.append(CorpusEntry(
                input: repeat each input,
                sparseCoverage: sparse
            ))
            return true
        }

        // Check if this is a new code path (signature hash not seen before)
        let hash = sparse.signatureHash
        guard !signatureHashes.contains(hash) else {
            return false
        }

        // New code path found - add to corpus
        let storage = bitmapStorage
        let capacity = bitmapCapacity
        bitmapCount += Self.bitmapMergeSparse(sparse, storage: storage, capacity: capacity)
        signatureHashes.insert(hash)

        entries.append(CorpusEntry(
            input: repeat each input,
            sparseCoverage: sparse
        ))
        return true
    }

    /// Add an entry unconditionally.
    func add(
        input: (repeat each Input),
        sparse: SparseCoverage,
        entryType: CorpusEntryType = .coverage,
        failure: FailureInfo? = nil
    ) {
        let entry = CorpusEntry(
            input: repeat each input,
            sparseCoverage: sparse,
            entryType: entryType,
            failure: failure
        )
        entries.append(entry)
        bitmapMergeSparse(sparse)
        signatureHashes.insert(sparse.signatureHash)
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

/// Coding keys for Corpus serialization.
private enum CorpusCodingKeys: String, CodingKey {
    case entries
    case coveredIndices
}

// MARK: - Corpus Snapshot

/// A serializable snapshot of corpus state.
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
        var container = encoder.container(keyedBy: CorpusCodingKeys.self)
        try container.encode(entries, forKey: .entries)
        try container.encode(coveredIndices, forKey: .coveredIndices)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CorpusCodingKeys.self)
        self.entries = try container.decode([CorpusEntry<repeat each Input>].self, forKey: .entries)
        self.coveredIndices = try container.decode(Set<UInt32>.self, forKey: .coveredIndices)
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
