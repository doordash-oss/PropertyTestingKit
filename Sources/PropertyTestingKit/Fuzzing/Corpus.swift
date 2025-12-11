//
//  Corpus.swift
//  PropertyTestingKit
//
//  Storage and management of fuzzing inputs with coverage signatures.
//

import Dependencies
import Foundation

// MARK: - CorpusEntry

/// A single entry in the corpus: an input and its coverage signature.
public struct CorpusEntry<each Input: Codable & Sendable>: Sendable, Codable {
    /// The test input.
    public let input: (repeat each Input)

    /// The coverage signature produced by this input.
    public let signature: CoverageSignature

    /// When this entry was discovered.
    public let discoveredAt: Date

    /// Optional: the parent input this was mutated from.
    public let parentIndex: Int?

    public init(
        input: repeat each Input,
        signature: CoverageSignature,
        discoveredAt: Date = Date(),
        parentIndex: Int? = nil
    ) {
        self.input = (repeat each input)
        self.signature = signature
        self.discoveredAt = discoveredAt
        self.parentIndex = parentIndex
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CorpusEntryCodingKeys.self)
        var dataList = [Data]()
        (repeat try dataList.append(JSONEncoder().encode(each input)))

        try container.encode(dataList, forKey: .input)

        try container.encode(signature, forKey: .signature)
        try container.encode(discoveredAt, forKey: .discoveredAt)
        try container.encodeIfPresent(parentIndex, forKey: .parentIndex)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CorpusEntryCodingKeys.self)
        let dataList = try container.decode([Data].self, forKey: .input)
        var dataIterator = dataList.makeIterator()

        let jsonDecoder = JSONDecoder()

        self.input = try (repeat jsonDecoder.decode((each Input).self, from: dataIterator.next()!))

        self.signature = try container.decode(CoverageSignature.self, forKey: .signature)
        self.discoveredAt = try container.decode(Date.self, forKey: .discoveredAt)
        self.parentIndex = try container.decodeIfPresent(Int.self, forKey: .parentIndex)
    }
}

public enum CorpusEntryCodingKeys: String, CodingKey {
    case input
    case signature
    case discoveredAt
    case parentIndex
}

// MARK: - Corpus

/// A collection of test inputs with their coverage signatures.
///
/// The corpus tracks which inputs produce unique coverage and provides
/// minimization to keep only the essential inputs.
public struct Corpus<Input: Codable & Sendable>: Sendable, Codable {
    /// All entries in the corpus.
    public private(set) var entries: [CorpusEntry<Input>]

    /// Schema version to detect when code changes invalidate the corpus.
    public let schemaVersion: String

    /// When this corpus was created.
    public let createdAt: Date

    /// When this corpus was last updated.
    public private(set) var updatedAt: Date

    /// The union of all coverage signatures.
    public private(set) var totalCoverage: CoverageSignature

    public init(schemaVersion: String) {
        self.entries = []
        self.schemaVersion = schemaVersion
        self.createdAt = Date()
        self.updatedAt = Date()
        self.totalCoverage = CoverageSignature(buckets: [:])
    }

    /// Number of entries in the corpus.
    public var count: Int { entries.count }

    /// Whether the corpus is empty.
    public var isEmpty: Bool { entries.isEmpty }

    /// All inputs in the corpus.
    public var inputs: [Input] {
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
    public mutating func addIfInteresting(
        input: Input,
        signature: CoverageSignature,
        parentIndex: Int? = nil
    ) -> Bool {
        // Check if this signature adds new coverage
        guard signature.hasUniqueCoverage(comparedTo: totalCoverage) else {
            return false
        }

        let entry = CorpusEntry(
            input: input,
            signature: signature,
            parentIndex: parentIndex
        )
        entries.append(entry)
        totalCoverage = totalCoverage.union(with: signature)
        updatedAt = Date()
        return true
    }

    /// Add an entry unconditionally.
    public mutating func add(
        input: Input,
        signature: CoverageSignature,
        parentIndex: Int? = nil
    ) {
        let entry = CorpusEntry(
            input: input,
            signature: signature,
            parentIndex: parentIndex
        )
        entries.append(entry)
        totalCoverage = totalCoverage.union(with: signature)
        updatedAt = Date()
    }

    // MARK: - Minimization

    /// Minimize the corpus to the smallest set that covers all unique signatures.
    ///
    /// Uses a greedy algorithm: repeatedly select the entry that covers the
    /// most uncovered indices until all indices are covered.
    ///
    /// - Returns: A new minimized corpus.
    public func minimized() -> Corpus<Input> {
        guard !entries.isEmpty else { return self }

        var minimized = Corpus<Input>(schemaVersion: schemaVersion)
        var uncovered = totalCoverage.executedIndices

        // Sort entries by coverage count (descending) for greedy selection
        var remaining = entries.enumerated().map { ($0.offset, $0.element) }

        while !uncovered.isEmpty && !remaining.isEmpty {
            // Find entry that covers the most uncovered indices.
            // Invariant: at least one remaining entry must cover at least one
            // uncovered index, since every index in totalCoverage came from
            // an entry's signature.
            var bestIndex = 0
            var bestCoverage = 0

            for (i, (_, entry)) in remaining.enumerated() {
                let covers = entry.signature.executedIndices.intersection(uncovered).count
                if covers > bestCoverage {
                    bestCoverage = covers
                    bestIndex = i
                }
            }

            // Add the best entry
            let (_, bestEntry) = remaining.remove(at: bestIndex)
            minimized.add(
                input: bestEntry.input,
                signature: bestEntry.signature,
                parentIndex: bestEntry.parentIndex
            )

            // Remove covered indices
            uncovered.subtract(bestEntry.signature.executedIndices)
        }

        return minimized
    }

    // MARK: - Selection for Mutation

    /// Select an entry for mutation using energy-based scheduling.
    ///
    /// Entries that cover rare indices get higher priority.
    public func selectForMutation() -> Int? {
        guard !entries.isEmpty else { return nil }

        // Calculate how rare each index is
        var indexFrequency: [Int: Int] = [:]
        for entry in entries {
            for index in entry.signature.executedIndices {
                indexFrequency[index, default: 0] += 1
            }
        }

        // Score each entry by sum of (1 / frequency) for its indices.
        // By iterating over indexFrequency keys, we avoid any optional handling.
        var scores = Array(repeating: 0.0, count: entries.count)
        for (index, freq) in indexFrequency {
            let contribution = 1.0 / Double(freq)
            for (i, entry) in entries.enumerated() {
                if entry.signature.executedIndices.contains(index) {
                    scores[i] += contribution
                }
            }
        }

        // Weighted random selection
        let totalScore = scores.reduce(0, +)
        guard totalScore > 0 else { return entries.indices.randomElement() }

        var random = Double.random(in: 0..<totalScore)

        // Iterate through all but the last score. If we don't return early,
        // the last entry is selected by elimination.
        for (i, score) in scores.dropLast().enumerated() {
            random -= score
            if random <= 0 {
                return i
            }
        }

        return scores.count - 1
    }
}

// MARK: - Corpus Persistence

extension Corpus {
    /// The filename for corpus storage.
    public static var filename: String { "corpus.json" }

    /// Save the corpus to a directory.
    public func save(to directory: URL) throws {
        @Dependency(\.fileManager) var fileManager
        try fileManager.createDirectory(directory, true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(self)
        let fileURL = directory.appendingPathComponent(Self.filename)
        try fileManager.writeData(data, fileURL)
    }

    /// Load a corpus from a directory.
    public static func load(from directory: URL) throws -> Corpus<Input> {
        @Dependency(\.fileManager) var fileManager
        let fileURL = directory.appendingPathComponent(filename)
        let data = try fileManager.readData(fileURL)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        return try decoder.decode(Corpus<Input>.self, from: data)
    }

    /// Check if a corpus exists at the given directory.
    public static func exists(at directory: URL) -> Bool {
        @Dependency(\.fileManager) var fileManager
        let fileURL = directory.appendingPathComponent(filename)
        return fileManager.fileExists(fileURL.path)
    }

    /// Delete a corpus from a directory.
    public static func delete(from directory: URL) throws {
        @Dependency(\.fileManager) var fileManager
        let fileURL = directory.appendingPathComponent(filename)
        if fileManager.fileExists(fileURL.path) {
            try fileManager.removeItem(fileURL)
        }
    }
}

// MARK: - Schema Versioning

/// Utilities for generating schema versions from coverage mapping.
public enum CorpusSchema {
    /// Generate a schema version from the current coverage mapping.
    ///
    /// This creates a hash of the coverage structure so we can detect
    /// when code changes invalidate the corpus.
    public static func currentVersion() -> String {
        @Dependency(\.coverageCounters) var coverageCounters
        return currentVersion(using: coverageCounters)
    }

    /// Generate a schema version using a specific coverage counters client.
    /// This overload enables testing with mocked dependencies.
    public static func currentVersion(using coverageCounters: CoverageCountersClient) -> String {
        // Use a hash of:
        // 1. Number of counters
        // 2. Build timestamp or similar

        guard let counters = coverageCounters.snapshot() else {
            return "unknown"
        }

        // Simple version: just the counter count
        // In practice, we'd hash more metadata
        return "v1-\(counters.count)"
    }

    /// Check if a schema version is compatible with the current code.
    public static func isCompatible(_ version: String) -> Bool {
        version == currentVersion()
    }
}
