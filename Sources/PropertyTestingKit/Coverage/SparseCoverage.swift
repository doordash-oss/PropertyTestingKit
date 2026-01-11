//
//  SparseCoverage.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

/// Efficient representation of sparse coverage data.
///
/// This is significantly faster than `Set<Int>` for the common case of
/// building coverage signatures, as it avoids hashing overhead during collection.
public struct SparseCoverage: Sendable {
    /// Edge indices that were executed.
    public let indices: [UInt32]

    /// Number of covered edges.
    public var count: Int { indices.count }

    /// Whether any edges were covered.
    public var isEmpty: Bool { indices.isEmpty }

    /// Create from an indices array.
    public init(indices: [UInt32]) {
        self.indices = indices
    }

    /// Create an empty sparse coverage.
    public init() {
        self.indices = []
    }
}
