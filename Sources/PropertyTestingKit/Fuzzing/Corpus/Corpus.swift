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
/// Thread safety: Access is serialized by `FuzzStateMachine` actor, so this
/// class does not need its own actor isolation.
public final class Corpus<each Input: Codable & Sendable>: @unchecked Sendable {

    /// All entries in the corpus.
    public private(set) var entries: [CorpusEntry<repeat each Input>]

    /// The union of all coverage signatures.
    public private(set) var totalCoverage: CoverageSignature

    init(entries: [CorpusEntry<repeat each Input>], totalCoverage: CoverageSignature) {
        self.entries = entries
        self.totalCoverage = totalCoverage
    }

    init() {
        self.entries = []
        self.totalCoverage = CoverageSignature(edges: [])
    }

    // MARK: - Serialization
    // Use CorpusSnapshot for serialization and create Corpus via init(from:CorpusSnapshot).

    /// Create a snapshot of the corpus state for encoding.
    func snapshot() -> CorpusSnapshot<repeat each Input> {
        CorpusSnapshot(
            entries: entries,
            totalCoverage: totalCoverage
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
    public var signatures: [CoverageSignature] {
        entries.map(\.signature)
    }

    // MARK: - Adding Entries

    /// Add an entry if it contributes new coverage.
    ///
    /// - Returns: `true` if the entry was added, `false` if it was redundant.
    @discardableResult
    func addIfInteresting(
        input: repeat each Input,
        signature: CoverageSignature
    ) -> Bool {
        return addIfInteresting(
            input: (repeat each input),
            signature: signature
        )
    }

    @discardableResult
    func addIfInteresting(
        input: (repeat each Input),
        signature: CoverageSignature
    ) -> Bool {
        // Check if this signature adds new coverage
        guard signature.hasUniqueCoverage(comparedTo: totalCoverage) else {
            return false
        }

        let entry = CorpusEntry(
            input: repeat each input,
            signature: signature
        )
        entries.append(entry)
        totalCoverage.merge(with: signature)
        return true
    }

    /// Add an entry if it contributes new coverage.
    /// Optimized to avoid creating a CoverageSignature unless coverage is interesting.
    ///
    /// - Returns: `true` if the entry was added, `false` if it was redundant.
    @discardableResult
    func addIfInterestingSparse(
        input: (repeat each Input),
        sparse: SparseCoverage
    ) -> Bool {
        // Check if this sparse coverage adds new coverage without creating a Set
        guard totalCoverage.hasUniqueCoverage(sparse: sparse) else {
            return false
        }

        // Only create the signature when we know it's interesting
        let signature = CoverageSignature(sparse: sparse)
        let entry = CorpusEntry(
            input: repeat each input,
            signature: signature
        )
        entries.append(entry)
        totalCoverage.merge(with: signature)
        return true
    }

    /// Add an entry unconditionally.
    func add(
        input: repeat each Input,
        signature: CoverageSignature,
        entryType: CorpusEntryType = .coverage,
        failure: FailureInfo? = nil
    ) {
        add(
            input: (repeat each input),
            signature: signature,
            entryType: entryType,
            failure: failure
        )
    }

    func add(
        input: (repeat each Input),
        signature: CoverageSignature,
        entryType: CorpusEntryType = .coverage,
        failure: FailureInfo? = nil
    ) {
        let entry = CorpusEntry(
            input: repeat each input,
            signature: signature,
            entryType: entryType,
            failure: failure
        )
        entries.append(entry)
        totalCoverage.merge(with: signature)
    }

    // MARK: - Minimization

    /// Minimize the corpus to the smallest set that covers all unique signatures.
    ///
    /// Uses a greedy algorithm: repeatedly select the entry that covers the
    /// most uncovered indices until all indices are covered.
    ///
    /// **Important:** Failure entries are ALWAYS preserved during minimization
    /// to prevent regression of discovered bugs. This follows Elhage 2020's recommendation
    /// that "previously-failing cases must be preserved during minimization."
    ///
    /// - Returns: A snapshot of the minimized corpus.
    func minimized() -> CorpusSnapshot<repeat each Input> {
        guard !entries.isEmpty else { return snapshot() }

        var minimizedEntries: [CorpusEntry<repeat each Input>] = []
        var minimizedCoverage = CoverageSignature(edges: [])
        var uncovered = totalCoverage.executedIndices

        // First, preserve ALL failure entries - these are never removed
        // during minimization to prevent regression of discovered bugs.
        var remainingCoverage = entries.enumerated().map { ($0.offset, $0.element) }
        var indicesToRemove: [Int] = []

        for (i, (_, entry)) in remainingCoverage.enumerated() {
            if entry.entryType == .failure {
                minimizedEntries.append(entry)
                minimizedCoverage.merge(with: entry.signature)
                entry.signature.subtractIndices(from: &uncovered)
                indicesToRemove.append(i)
            }
        }

        // Remove preserved entries from remaining pool (in reverse order to maintain indices)
        for index in indicesToRemove.reversed() {
            remainingCoverage.remove(at: index)
        }

        // Now use greedy algorithm for remaining coverage-based entries
        while !uncovered.isEmpty && !remainingCoverage.isEmpty {
            // Find entry that covers the most uncovered indices.
            var bestIndex = 0
            var bestCoverageCount = 0

            for (i, (_, entry)) in remainingCoverage.enumerated() {
                let covers = entry.signature.countIndicesIn(uncovered)
                if covers > bestCoverageCount {
                    bestCoverageCount = covers
                    bestIndex = i
                }
            }

            // If no entry covers any uncovered indices, we're done
            if bestCoverageCount == 0 {
                break
            }

            // Add the best entry
            let (_, bestEntry) = remainingCoverage.remove(at: bestIndex)
            minimizedEntries.append(bestEntry)
            minimizedCoverage.merge(with: bestEntry.signature)

            // Remove covered indices
            bestEntry.signature.subtractIndices(from: &uncovered)
        }

        return CorpusSnapshot(
            entries: minimizedEntries,
            totalCoverage: minimizedCoverage
        )
    }

}

/// Coding keys for Corpus serialization.
/// Note: Must be declared outside the generic struct due to parameter pack limitations.
private enum CorpusCodingKeys: String, CodingKey {
    case entries
    case totalCoverage
}

// MARK: - Corpus Snapshot

/// A serializable snapshot of corpus state.
///
/// This struct captures the corpus state for serialization.
public struct CorpusSnapshot<each Input: Codable & Sendable>: Sendable, Codable {
    public let entries: [CorpusEntry<repeat each Input>]
    public let totalCoverage: CoverageSignature

    public init(
        entries: [CorpusEntry<repeat each Input>],
        totalCoverage: CoverageSignature
    ) {
        self.entries = entries
        self.totalCoverage = totalCoverage
    }

    /// Number of entries in the snapshot.
    public var count: Int { entries.count }

    /// Whether the snapshot is empty.
    public var isEmpty: Bool { entries.isEmpty }

    // MARK: - Codable

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CorpusCodingKeys.self)
        try container.encode(entries, forKey: .entries)
        try container.encode(totalCoverage, forKey: .totalCoverage)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CorpusCodingKeys.self)
        self.entries = try container.decode([CorpusEntry<repeat each Input>].self, forKey: .entries)
        self.totalCoverage = try container.decode(CoverageSignature.self, forKey: .totalCoverage)
    }
}

extension Corpus {
    /// Create a corpus from a snapshot.
    convenience init(from snapshot: CorpusSnapshot<repeat each Input>) {
        self.init(
            entries: snapshot.entries,
            totalCoverage: snapshot.totalCoverage
        )
    }
}
