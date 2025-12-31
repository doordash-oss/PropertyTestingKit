//
//  Array+Shrinkable.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

extension Array: Shrinkable {
    public var shrinkableElementCount: Int { count }

    public func candidateRemovingRange(_ range: Range<Int>) -> [Element]? {
        guard range.lowerBound >= 0, range.upperBound <= count else { return nil }
        var copy = self
        copy.removeSubrange(range)
        return copy
    }

    public func simplifiedCandidates() -> [[Element]] {
        // For arrays, simplification is removal, which is handled by candidateRemovingRange
        []
    }
}
