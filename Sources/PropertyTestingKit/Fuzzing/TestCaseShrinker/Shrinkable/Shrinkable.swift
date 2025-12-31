//
//  Shrinkable.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

/// A type that can be shrunk (reduced to simpler/smaller forms).
///
/// Provides structure-aware shrinking for complex types.
public protocol Shrinkable {
    /// Number of elements that can potentially be removed.
    var shrinkableElementCount: Int { get }

    /// Generate candidates by removing a range of elements.
    /// - Parameter range: The range of element indices to remove.
    /// - Returns: A candidate with those elements removed, or nil if not possible.
    func candidateRemovingRange(_ range: Range<Int>) -> Self?

    /// Generate candidates by simplifying elements (without removing them).
    /// - Returns: Array of simplified candidates.
    func simplifiedCandidates() -> [Self]
}
