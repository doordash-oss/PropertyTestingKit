//
//  CoverageSignature.swift
//  PropertyTestingKit
//
//  A stable representation of code coverage for comparing test inputs.
//

import Foundation

// MARK: - CoverageSignature

/// A stable representation of coverage state that can be compared across runs.
///
/// Stores the set of edge indices that were executed. Two inputs with the same
/// signature exercised the same code paths. Different signatures indicate
/// different coverage.
public struct CoverageSignature: Hashable, Sendable {
    /// The set of edge indices that were executed.
    /// Only non-zero edges are stored for efficiency.
    public private(set) var edges: Set<Int>

    /// Create a signature from raw counter values.
    public init(counters: [UInt64]) {
        var edges: Set<Int> = []
        for (index, count) in counters.enumerated() {
            if count > 0 {
                edges.insert(index)
            }
        }
        self.edges = edges
    }

    /// Create a signature from a SanCovCounters snapshot.
    public init(snapshot: SanCovCounters) {
        var edges: Set<Int> = []
        for (index, count) in snapshot.counters.enumerated() {
            if count > 0 {
                edges.insert(index)
            }
        }
        self.edges = edges
    }

    /// Create directly from edges (for testing/deserialization).
    public init(edges: Set<Int>) {
        self.edges = edges
    }

    /// Create a signature from sparse coverage data.
    ///
    /// This is the fastest way to create a signature from coverage data,
    /// as it avoids hashing overhead during collection.
    ///
    /// - Parameter sparse: SparseCoverage with indices array.
    public init(sparse: SparseCoverage) {
        self.edges = Set((0..<sparse.count).map { Int(sparse.indices[$0]) })
    }

    /// Number of edges that were executed.
    public var executedCount: Int {
        edges.count
    }

    /// Whether this signature represents any coverage at all.
    public var isEmpty: Bool {
        edges.isEmpty
    }

    /// The set of edge indices that were executed.
    public var executedIndices: Set<Int> {
        edges
    }

    /// Remove this signature's executed indices from the given set.
    /// More efficient than `set.subtract(executedIndices)` as it avoids
    /// creating an intermediate Set.
    public func subtractIndices(from set: inout Set<Int>) {
        set.subtract(edges)
    }

    /// Count how many of this signature's indices are in the given set.
    /// More efficient than `executedIndices.intersection(set).count` as it
    /// avoids creating intermediate Sets.
    public func countIndicesIn(_ set: Set<Int>) -> Int {
        edges.intersection(set).count
    }

    // MARK: - Comparison

    /// Returns the indices covered by this signature but not the other.
    public func uniqueIndices(comparedTo other: CoverageSignature) -> Set<Int> {
        edges.subtracting(other.edges)
    }

    /// Returns the indices covered by both signatures.
    public func commonIndices(with other: CoverageSignature) -> Set<Int> {
        edges.intersection(other.edges)
    }

    /// Returns whether this signature covers any indices not in the other.
    ///
    /// Optimized to return early on first unique index found.
    public func hasUniqueCoverage(comparedTo other: CoverageSignature) -> Bool {
        !edges.isSubset(of: other.edges)
    }

    /// Returns the union of this signature with another.
    public func union(with other: CoverageSignature) -> CoverageSignature {
        CoverageSignature(edges: edges.union(other.edges))
    }

    /// Merges another signature into this one in-place.
    /// More efficient than `union(with:)` when accumulating coverage.
    public mutating func merge(with other: CoverageSignature) {
        edges.formUnion(other.edges)
    }
}

// MARK: - CustomStringConvertible

extension CoverageSignature: CustomStringConvertible {
    public var description: String {
        "CoverageSignature(\(executedCount) edges)"
    }
}

// MARK: - Codable

extension CoverageSignature: Codable {
    private enum CodingKeys: String, CodingKey {
        case edges
        case buckets  // Legacy format for backwards compatibility
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Try new format first
        if let edges = try? container.decode(Set<Int>.self, forKey: .edges) {
            self.edges = edges
            return
        }

        // Fall back to legacy buckets format: {"1": 1, "5": 1} -> edges [1, 5]
        // The bucket values are ignored since we only care about which edges were hit
        if let buckets = try? container.decode([String: Int].self, forKey: .buckets) {
            self.edges = Set(buckets.keys.compactMap { Int($0) })
            return
        }

        // If neither format works, default to empty
        self.edges = []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(edges, forKey: .edges)
    }
}

// MARK: - Signature Collection

/// A collection of coverage signatures with utilities for analysis.
public struct SignatureSet: Codable, Sendable {
    /// All unique signatures seen.
    public private(set) var signatures: Set<CoverageSignature>

    /// The union of all coverage (all indices ever executed).
    public private(set) var totalCoverage: CoverageSignature

    public init() {
        self.signatures = []
        self.totalCoverage = CoverageSignature(edges: [])
    }

    /// Add a signature to the set.
    /// Returns true if this signature was new (not seen before).
    @discardableResult
    public mutating func insert(_ signature: CoverageSignature) -> Bool {
        let isNew = signatures.insert(signature).inserted
        totalCoverage.merge(with: signature)
        return isNew
    }

    /// Check if a signature would add new coverage.
    public func wouldAddNewCoverage(_ signature: CoverageSignature) -> Bool {
        signature.hasUniqueCoverage(comparedTo: totalCoverage)
    }

    /// Number of unique signatures.
    public var count: Int {
        signatures.count
    }

    /// Total number of unique edge indices covered.
    public var totalCoveredIndices: Int {
        totalCoverage.executedCount
    }
}
