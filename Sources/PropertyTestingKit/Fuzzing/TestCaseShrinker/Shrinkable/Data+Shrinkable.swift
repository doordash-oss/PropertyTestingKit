//
//  Data+Shrinkable.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Foundation

extension Data: Shrinkable {
    var shrinkableElementCount: Int { count }

    func candidateRemovingRange(_ range: Range<Int>) -> Data? {
        guard range.lowerBound >= 0, range.upperBound <= count else { return nil }
        var copy = self
        copy.removeSubrange(range)
        return copy
    }

    func simplifiedCandidates() -> [Data] {
        // Try zeroing out the data
        if self != Data(repeating: 0, count: self.count) {
            return [Data(repeating: 0, count: self.count)]
        }
        return []
    }
}
