//
//  SparseCoverage.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

/// Efficient representation of sparse coverage data.
///
/// This is significantly faster than `Set<Int>` for the common case of
/// building coverage signatures, as it avoids hashing overhead during collection.
public struct SparseCoverage: Sendable, Codable, Equatable {
    /// Edge indices that were executed.
    public let indices: [UInt32]

    /// Number of covered edges.
    public var count: Int { indices.count }

    /// Whether any edges were covered.
    public var isEmpty: Bool { indices.isEmpty }

    /// Hash of the coverage signature for fast uniqueness checking.
    /// Two SparseCoverage instances with the same indices will have the same hash.
    /// Used by Corpus to detect unique code paths.
    public var signatureHash: Int {
        // Golden ratio primes for mixing (as signed Int using bitPattern)
        let indexPrime = Int(bitPattern: 0x9e3779b97f4a7c15 as UInt)
        let countPrime = Int(bitPattern: 0x517cc1b727220a95 as UInt)

        // Use a simple but effective hash combining function
        // Order-independent since indices may not be sorted
        var hash = 0
        for index in indices {
            // XOR with a mixed version of each index to reduce collisions
            let mixed = Int(index) &* indexPrime
            hash ^= mixed
        }
        // Mix in the count to differentiate signatures with same XOR but different counts
        hash ^= indices.count &* countPrime
        return hash
    }

    /// Create from an indices array.
    @inlinable
    public init(indices: [UInt32] = []) {
        self.indices = indices
    }

    // MARK: - Set Operations for Minimization

    /// Count how many of this coverage's indices are in the given set.
    /// Used by the minimization algorithm.
    public func countIndicesIn(_ set: Set<UInt32>) -> Int {
        var count = 0
        for index in indices {
            if set.contains(index) {
                count += 1
            }
        }
        return count
    }

    /// Remove this coverage's indices from the given set.
    /// Used by the minimization algorithm.
    public func subtractIndices(from set: inout Set<UInt32>) {
        for index in indices {
            set.remove(index)
        }
    }
}
