//
//  Array+Shrinkable.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

extension Array: Shrinkable {
    var shrinkableElementCount: Int { count }

    func candidateRemovingRange(_ range: Range<Int>) -> [Element]? {
        guard range.lowerBound >= 0, range.upperBound <= count else { return nil }
        var copy = self
        copy.removeSubrange(range)
        return copy
    }

    func simplifiedCandidates() -> [[Element]] {
        // For arrays, simplification is removal, which is handled by candidateRemovingRange
        []
    }
}
