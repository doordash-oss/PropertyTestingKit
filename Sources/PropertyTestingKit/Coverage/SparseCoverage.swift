//
//  SparseCoverage.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

/// Efficient representation of sparse coverage data.
///
/// This is significantly faster than `Set<Int>` for the common case of
/// building coverage signatures, as it avoids hashing overhead during collection.
struct SparseCoverage: Sendable {
    /// Edge indices that were executed.
    let indices: [UInt32]

    /// Number of covered edges.
    var count: Int { indices.count }

    /// Whether any edges were covered.
    var isEmpty: Bool { indices.isEmpty }

    /// Create from an indices array.
    init(indices: [UInt32] = []) {
        self.indices = indices
    }
}
