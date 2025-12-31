//
//  Array+Fuzzable.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

extension Array: Fuzzable where Element: Fuzzable {
    public static var fuzz: [[Element]] {
        var result: [[Element]] = [[]]

        let elementSeeds = Array(Element.fuzz.prefix(3))
        guard !elementSeeds.isEmpty else { return result }

        // Single element arrays with first few seeds
        for element in elementSeeds {
            result.append([element])
        }

        // Small multi-element array from seeds (provides variety)
        if elementSeeds.count >= 3 {
            result.append(elementSeeds)
        }

        return result
    }

    public func mutate() -> [[Element]] {
        var mutations: [[Element]] = []

        // === Removal mutations ===
        for i in indices {
            var copy = self
            copy.remove(at: i)
            mutations.append(copy)
        }

        // === Append elements (incremental growth) ===
        for element in Element.fuzz.prefix(3) {
            mutations.append(self + [element])
        }

        // === Prepend element ===
        for element in Element.fuzz.prefix(2) {
            mutations.append([element] + self)
        }

        // === Array doubling (exponential growth) ===
        // No cap - allows arrays to grow to any size needed.
        // Value profile guidance will prioritize growth when comparisons
        // like `count >= 100` are encountered.
        if count > 0 {
            mutations.append(self + self)
        }

        // === Mutate individual elements ===
        for i in indices {
            for mutated in self[i].mutate().prefix(2) {
                var copy = self
                copy[i] = mutated
                mutations.append(copy)
            }
        }

        // === Reversal ===
        if count > 1 {
            mutations.append(reversed())
        }

        return mutations
    }
}
