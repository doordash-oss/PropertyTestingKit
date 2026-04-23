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

//  A bitmap-based coverage storage optimized for zero ARC overhead.
//
//  This replaces Set<UInt32> for tracking covered edges, eliminating the
//  ~2000 retain/release cycles per Set operation that dominated profiling.
//

import Foundation

/// A bitmap for tracking covered edge indices with zero ARC overhead.
///
/// Unlike `Set<UInt32>`, this structure uses a raw pointer to a fixed-size
/// bitmap, eliminating all retain/release cycles during hot path operations.
///
/// Thread safety: This class is NOT thread-safe. Access must be serialized
/// externally (e.g., by the `FuzzStateMachine` actor).
@usableFromInline
final class CoverageBitmap: @unchecked Sendable {
    /// The bitmap storage - each bit represents one edge index.
    @usableFromInline
    let storage: UnsafeMutablePointer<UInt64>

    /// Number of UInt64 words in the bitmap.
    @usableFromInline
    let wordCount: Int

    /// Total capacity in bits.
    @usableFromInline
    let capacity: Int

    /// Number of set bits (cached for O(1) count access).
    @usableFromInline
    var _count: Int = 0

    /// Create a bitmap with capacity for the given number of edges.
    ///
    /// - Parameter capacity: Maximum edge index + 1. Pass 0 for an empty bitmap.
    @usableFromInline
    init(capacity: Int) {
        self.capacity = capacity
        self.wordCount = (capacity + 63) / 64
        if wordCount > 0 {
            self.storage = .allocate(capacity: wordCount)
            self.storage.initialize(repeating: 0, count: wordCount)
        } else {
            // Allocate a minimal buffer to avoid nil checks
            self.storage = .allocate(capacity: 1)
            self.storage.initialize(to: 0)
        }
    }

    deinit {
        storage.deallocate()
    }

    /// Number of covered edges.
    @inlinable
    var count: Int { _count }

    /// Whether no edges are covered.
    @inlinable
    var isEmpty: Bool { _count == 0 }

    /// Check if an edge index is covered.
    ///
    /// - Parameter index: The edge index to check.
    /// - Returns: `true` if the edge is covered.
    @inlinable
    func contains(_ index: UInt32) -> Bool {
        let i = Int(index)
        guard i < capacity else { return false }
        let wordIndex = i >> 6  // i / 64
        let bitIndex = i & 63   // i % 64
        return (storage[wordIndex] & (1 << bitIndex)) != 0
    }

    /// Mark an edge index as covered.
    ///
    /// - Parameter index: The edge index to mark.
    /// - Returns: `true` if the edge was newly covered, `false` if already covered.
    @inlinable
    @discardableResult
    func insert(_ index: UInt32) -> Bool {
        let i = Int(index)
        guard i < capacity else { return false }
        let wordIndex = i >> 6
        let bitIndex = i & 63
        let mask: UInt64 = 1 << bitIndex
        let oldWord = storage[wordIndex]
        if (oldWord & mask) != 0 {
            return false  // Already set
        }
        storage[wordIndex] = oldWord | mask
        _count += 1
        return true
    }

    /// Check if any indices in the sparse coverage are NOT in this bitmap.
    ///
    /// This is the hot path for `addIfInteresting` - we want to know if the
    /// new coverage adds anything we haven't seen before.
    ///
    /// - Parameter sparse: The sparse coverage to check.
    /// - Returns: `true` if sparse contains at least one new index.
    @inlinable
    func hasUniqueCoverage(sparse: borrowing SparseCoverage) -> Bool {
        for index in sparse.indices {
            if !contains(index) {
                return true
            }
        }
        return false
    }

    /// Check if any indices in the raw pointer are NOT in this bitmap.
    ///
    /// This avoids creating a Swift Array when checking coverage.
    /// Use this before allocating SparseCoverage to avoid unnecessary allocations.
    ///
    /// - Parameters:
    ///   - indices: Raw pointer to UInt32 indices from C code.
    ///   - count: Number of indices in the pointer.
    /// - Returns: `true` if any index is not in this bitmap.
    @inlinable
    func hasUniqueCoverage(indices: UnsafePointer<UInt32>, count: Int) -> Bool {
        for i in 0..<count {
            if !contains(indices[i]) {
                return true
            }
        }
        return false
    }

    /// Merge sparse coverage into this bitmap.
    ///
    /// - Parameter sparse: The sparse coverage to merge.
    @inlinable
    func mergeSparse(_ sparse: borrowing SparseCoverage) {
        for index in sparse.indices {
            insert(index)
        }
    }

    /// Get all covered indices as a Set (for compatibility with existing code).
    ///
    /// This is an O(capacity) operation and should only be used for
    /// serialization or when interoperating with Set-based APIs.
    func executedIndices() -> Set<UInt32> {
        var result = Set<UInt32>()
        result.reserveCapacity(_count)
        for wordIndex in 0..<wordCount {
            var word = storage[wordIndex]
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

    /// Initialize from a Set of indices (for deserialization).
    convenience init(from indices: Set<UInt32>, capacity: Int) {
        self.init(capacity: capacity)
        for index in indices {
            insert(index)
        }
    }
}
