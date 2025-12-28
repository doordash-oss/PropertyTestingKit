//
//  SparseCoverage.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

/// Efficient representation of sparse coverage data using parallel arrays.
///
/// This is significantly faster than `[Int: UInt8]` because it avoids
/// Dictionary hashing overhead. The indices and counts arrays are parallel:
/// `counts[i]` is the hit count for edge `indices[i]`.
public struct SparseCoverage: Sendable {
    /// Edge indices that were executed.
    public let indices: [UInt32]

    /// Hit counts for each edge (parallel to indices).
    public let counts: [UInt8]

    /// Number of covered edges.
    public var count: Int { indices.count }

    /// Whether any edges were covered.
    public var isEmpty: Bool { indices.isEmpty }

    /// Create from parallel arrays.
    public init(indices: [UInt32], counts: [UInt8]) {
        precondition(indices.count == counts.count, "indices and counts must have same length")
        self.indices = indices
        self.counts = counts
    }

    /// Create an empty sparse coverage.
    public init() {
        self.indices = []
        self.counts = []
    }
}
