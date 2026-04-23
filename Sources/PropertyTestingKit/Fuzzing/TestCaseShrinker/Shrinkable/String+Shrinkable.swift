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

//
//  String+Shrinkable.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

extension String: Shrinkable {
    var shrinkableElementCount: Int { count }

    func candidateRemovingRange(_ range: Range<Int>) -> String? {
        let startIndex = self.index(self.startIndex, offsetBy: range.lowerBound, limitedBy: self.endIndex)
        let endIndex = self.index(self.startIndex, offsetBy: range.upperBound, limitedBy: self.endIndex)
        guard let start = startIndex, let end = endIndex else { return nil }

        var copy = self
        copy.removeSubrange(start..<end)
        return copy
    }

    func simplifiedCandidates() -> [String] {
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
