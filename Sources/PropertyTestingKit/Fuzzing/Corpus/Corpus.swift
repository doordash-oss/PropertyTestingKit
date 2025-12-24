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
public actor Corpus<each Input: Codable & Sendable>: Sendable {
    @Dependency(\.dateClient) var dateClient

    /// All entries in the corpus.
    public private(set) var entries: [CorpusEntry<repeat each Input>]

    /// Schema version to detect when code changes invalidate the corpus.
    public let schemaVersion: String

    /// When this corpus was created.
    public let createdAt: Date

    /// When this corpus was last updated.
    public private(set) var updatedAt: Date

    /// The union of all coverage signatures.
    public private(set) var totalCoverage: CoverageSignature

    init(entries: [CorpusEntry<repeat each Input>], schemaVersion: String, createdAt: Date, updatedAt: Date, totalCoverage: CoverageSignature) {
        self.entries = entries
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.totalCoverage = totalCoverage
    }

    public init(schemaVersion: String) async {
        @Dependency(\.dateClient) var dateClient
        let now = await dateClient.now()
        self.entries = []
        self.schemaVersion = schemaVersion
        self.createdAt = now
        self.updatedAt = now
        self.totalCoverage = CoverageSignature(buckets: [:])
    }

    // MARK: - Serialization
    // Note: Actors cannot conform to Codable directly.
    // Use CorpusSnapshot for serialization and create Corpus via init(from:CorpusSnapshot).

    /// Create a snapshot of the corpus state for encoding.
    public func snapshot() -> CorpusSnapshot<repeat each Input> {
        CorpusSnapshot(
            entries: entries,
            schemaVersion: schemaVersion,
            createdAt: createdAt,
            updatedAt: updatedAt,
            totalCoverage: totalCoverage
        )
    }

    /// Number of entries in the corpus.
    public var count: Int { entries.count }

    /// Whether the corpus is empty.
    public var isEmpty: Bool { entries.isEmpty }

    /// All inputs in the corpus.
    public var inputs: [(repeat each Input)] {
        // Note: Can't use map(\.input) due to keypath limitations with parameter packs
        var result: [(repeat each Input)] = []
        for entry in entries {
            result.append(entry.input)
        }
        return result
    }

    /// All signatures in the corpus.
    public var signatures: [CoverageSignature] {
        // Note: Can't use map(\.signature) consistently, using explicit loop
        var result: [CoverageSignature] = []
        for entry in entries {
            result.append(entry.signature)
        }
        return result
    }

    // MARK: - Adding Entries

    /// Add an entry if it contributes new coverage.
    ///
    /// - Returns: `true` if the entry was added, `false` if it was redundant.
    @discardableResult
    public func addIfInteresting(
        input: repeat each Input,
        signature: CoverageSignature,
        parentIndex: Int? = nil
    ) async -> Bool {
        return await addIfInteresting(
            input: (repeat each input),
            signature: signature,
            parentIndex: parentIndex
        )
    }

    @discardableResult
    public func addIfInteresting(
        input: (repeat each Input),
        signature: CoverageSignature,
        parentIndex: Int? = nil
    ) async -> Bool {
        // Check if this signature adds new coverage
        guard signature.hasUniqueCoverage(comparedTo: totalCoverage) else {
            return false
        }

        let entry = await CorpusEntry(
            input: repeat each input,
            signature: signature,
            parentIndex: parentIndex
        )
        entries.append(entry)
        totalCoverage = totalCoverage.union(with: signature)
        updatedAt = await dateClient.now()
        return true
    }

    /// Add an entry unconditionally.
    public func add(
        input: repeat each Input,
        signature: CoverageSignature,
        parentIndex: Int? = nil,
        entryType: CorpusEntryType = .coverage,
        failure: FailureInfo? = nil
    ) async {
        await add(
            input: (repeat each input),
            signature: signature,
            parentIndex: parentIndex,
            entryType: entryType,
            failure: failure
        )

    }

    public func add(
        input: (repeat each Input),
        signature: CoverageSignature,
        parentIndex: Int? = nil,
        entryType: CorpusEntryType = .coverage,
        failure: FailureInfo? = nil
    ) async {
        let entry = await CorpusEntry(
            input: repeat each input,
            signature: signature,
            parentIndex: parentIndex,
            entryType: entryType,
            failure: failure
        )
        entries.append(entry)
        totalCoverage = totalCoverage.union(with: signature)
        updatedAt = await dateClient.now()
    }

    // MARK: - Failure Statistics

    /// Number of failure-inducing entries in the corpus.
    public var failureCount: Int {
        entries.filter { $0.entryType == .failure }.count
    }

    /// Number of hang-inducing entries in the corpus.
    public var hangCount: Int {
        entries.filter { $0.entryType == .hang }.count
    }

    /// All failure entries.
    public var failureEntries: [CorpusEntry<repeat each Input>] {
        entries.filter { $0.entryType == .failure }
    }

    /// All hang entries.
    public var hangEntries: [CorpusEntry<repeat each Input>] {
        entries.filter { $0.entryType == .hang }
    }

    // MARK: - Minimization

    /// Minimize the corpus to the smallest set that covers all unique signatures.
    ///
    /// Uses a greedy algorithm: repeatedly select the entry that covers the
    /// most uncovered indices until all indices are covered.
    ///
    /// **Important:** Failure and hang entries are ALWAYS preserved during minimization
    /// to prevent regression of discovered bugs. This follows Elhage 2020's recommendation
    /// that "previously-failing cases must be preserved during minimization."
    ///
    /// - Returns: A snapshot of the minimized corpus.
    public func minimized() async -> CorpusSnapshot<repeat each Input> {
        guard !entries.isEmpty else { return snapshot() }

        var minimizedEntries: [CorpusEntry<repeat each Input>] = []
        var minimizedCoverage = CoverageSignature(buckets: [:])
        var uncovered = totalCoverage.executedIndices

        // First, preserve ALL failure and hang entries - these are never removed
        // during minimization to prevent regression of discovered bugs.
        var remainingCoverage = entries.enumerated().map { ($0.offset, $0.element) }
        var indicesToRemove: [Int] = []

        for (i, (_, entry)) in remainingCoverage.enumerated() {
            if entry.entryType == .failure || entry.entryType == .hang {
                minimizedEntries.append(entry)
                minimizedCoverage = minimizedCoverage.union(with: entry.signature)
                uncovered.subtract(entry.signature.executedIndices)
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
                let covers = entry.signature.executedIndices.intersection(uncovered).count
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
            minimizedCoverage = minimizedCoverage.union(with: bestEntry.signature)

            // Remove covered indices
            uncovered.subtract(bestEntry.signature.executedIndices)
        }

        @Dependency(\.dateClient) var dateClient
        return CorpusSnapshot(
            entries: minimizedEntries,
            schemaVersion: schemaVersion,
            createdAt: createdAt,
            updatedAt: await dateClient.now(),
            totalCoverage: minimizedCoverage
        )
    }

    // MARK: - Selection for Mutation

    /// Select an entry for mutation.
    ///
    /// Uses uniform random selection from the corpus.
    public func selectForMutation() -> Int? {
        guard !entries.isEmpty else { return nil }
        return entries.indices.randomElement()
    }
}

/// Coding keys for Corpus serialization.
/// Note: Must be declared outside the generic struct due to parameter pack limitations.
private enum CorpusCodingKeys: String, CodingKey {
    case entries
    case schemaVersion
    case createdAt
    case updatedAt
    case totalCoverage
}

// MARK: - Corpus Snapshot

/// A serializable snapshot of corpus state.
///
/// Since `Corpus` is an actor, it cannot directly conform to `Codable` in a
/// synchronous way. This struct captures the corpus state for serialization.
public struct CorpusSnapshot<each Input: Codable & Sendable>: Sendable, Codable {
    public let entries: [CorpusEntry<repeat each Input>]
    public let schemaVersion: String
    public let createdAt: Date
    public let updatedAt: Date
    public let totalCoverage: CoverageSignature

    public init(
        entries: [CorpusEntry<repeat each Input>],
        schemaVersion: String,
        createdAt: Date,
        updatedAt: Date,
        totalCoverage: CoverageSignature
    ) {
        self.entries = entries
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.totalCoverage = totalCoverage
    }

    /// Number of entries in the snapshot.
    public var count: Int { entries.count }

    /// Whether the snapshot is empty.
    public var isEmpty: Bool { entries.isEmpty }

    /// All inputs in the snapshot.
    public var inputs: [(repeat each Input)] {
        var result: [(repeat each Input)] = []
        for entry in entries {
            result.append(entry.input)
        }
        return result
    }

    // MARK: - Codable

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CorpusCodingKeys.self)
        try container.encode(entries, forKey: .entries)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(totalCoverage, forKey: .totalCoverage)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CorpusCodingKeys.self)
        self.entries = try container.decode([CorpusEntry<repeat each Input>].self, forKey: .entries)
        self.schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        self.totalCoverage = try container.decode(CoverageSignature.self, forKey: .totalCoverage)
    }
}

extension Corpus {
    /// Create a corpus from a snapshot.
    public init(from snapshot: CorpusSnapshot<repeat each Input>) {
        self.init(
            entries: snapshot.entries,
            schemaVersion: snapshot.schemaVersion,
            createdAt: snapshot.createdAt,
            updatedAt: snapshot.updatedAt,
            totalCoverage: snapshot.totalCoverage
        )
    }
}
