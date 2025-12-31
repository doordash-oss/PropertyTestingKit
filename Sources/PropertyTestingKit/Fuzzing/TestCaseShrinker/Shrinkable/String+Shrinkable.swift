//
//  String+Shrinkable.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

extension String: Shrinkable {
    public var shrinkableElementCount: Int { count }

    public func candidateRemovingRange(_ range: Range<Int>) -> String? {
        let startIndex = self.index(self.startIndex, offsetBy: range.lowerBound, limitedBy: self.endIndex)
        let endIndex = self.index(self.startIndex, offsetBy: range.upperBound, limitedBy: self.endIndex)
        guard let start = startIndex, let end = endIndex else { return nil }

        var copy = self
        copy.removeSubrange(start..<end)
        return copy
    }

    public func simplifiedCandidates() -> [String] {
        var candidates: [String] = []

        // Try replacing uppercase with lowercase
        let lowercased = self.lowercased()
        if lowercased != self {
            candidates.append(lowercased)
        }

        // Try replacing all characters with 'a'
        let simplified = String(repeating: "a", count: self.count)
        if simplified != self {
            candidates.append(simplified)
        }

        // Try empty string
        if !self.isEmpty {
            candidates.append("")
        }

        return candidates
    }
}
