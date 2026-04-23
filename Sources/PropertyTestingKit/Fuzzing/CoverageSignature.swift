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
    @usableFromInline
    var edges: Set<UInt32>

    /// Create directly from edges (for testing/deserialization).
    @usableFromInline
    init(edges: Set<UInt32>) {
        self.edges = edges
    }

    /// Create a signature from sparse coverage data.
    @usableFromInline
    init(sparse: consuming SparseCoverage) {
        self.edges = Set(sparse.indices)
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
    public var executedIndices: Set<UInt32> {
        edges
    }

    /// Remove this signature's executed indices from the given set.
    /// More efficient than `set.subtract(executedIndices)` as it avoids
    /// creating an intermediate Set.
    func subtractIndices(from set: inout Set<UInt32>) {
        set.subtract(edges)
    }

    /// Count how many of this signature's indices are in the given set.
    /// More efficient than `executedIndices.intersection(set).count` as it
    /// avoids creating intermediate Sets.
    func countIndicesIn(_ set: Set<UInt32>) -> Int {
        edges.intersection(set).count
    }

    // MARK: - Comparison

    /// Returns the indices covered by this signature but not the other.
    func uniqueIndices(comparedTo other: CoverageSignature) -> Set<UInt32> {
        edges.subtracting(other.edges)
    }

    /// Returns the indices covered by both signatures.
    func commonIndices(with other: CoverageSignature) -> Set<UInt32> {
        edges.intersection(other.edges)
    }

    /// Returns whether this signature covers any indices not in the other.
    ///
    /// Optimized to return early on first unique index found.
    func hasUniqueCoverage(comparedTo other: CoverageSignature) -> Bool {
        !edges.isSubset(of: other.edges)
    }

    /// Returns whether the sparse coverage contains any indices not in this signature.
    ///
    /// Optimized to avoid creating an intermediate Set - iterates over the array
    /// and checks each element against this signature's Set.
    /// Returns early on first unique index found.
    @usableFromInline
    func hasUniqueCoverage(sparse: borrowing SparseCoverage) -> Bool {
        for index in sparse.indices {
            if !edges.contains(index) {
                return true
            }
        }
        return false
    }

    /// Returns the union of this signature with another.
    func union(with other: CoverageSignature) -> CoverageSignature {
        CoverageSignature(edges: edges.union(other.edges))
    }

    /// Merges another signature into this one in-place.
    /// More efficient than `union(with:)` when accumulating coverage.
    @usableFromInline
    mutating func merge(with other: CoverageSignature) {
        edges.formUnion(other.edges)
    }

    /// Merges sparse coverage into this signature in-place.
    /// Avoids creating an intermediate Set from the sparse coverage.
    @usableFromInline
    mutating func mergeSparse(_ sparse: borrowing SparseCoverage) {
        for index in sparse.indices {
            edges.insert(index)
        }
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
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Try new format first
        if let edges = try? container.decode(Set<UInt32>.self, forKey: .edges) {
            self.edges = edges
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
