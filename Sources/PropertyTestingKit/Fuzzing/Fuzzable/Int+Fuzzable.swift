//
//  Int+Fuzzable.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

extension Int: Fuzzable {
    public static var fuzz: [Int] {
        [
            // Extremes and zero
            0,
            1,
            -1,
            Int.max,
            Int.min,

            // Small values useful for arithmetic relationships
            3,       // Common in b = a*k + 3 patterns
            7,       // Common factor
            10,      // Base 10

            // Common magic numbers (from security/hacking culture)
            42,      // "Answer to everything"
            1337,    // "leet" - extremely common in tests
            31337,   // "elite" - another common magic

            // Common range boundaries
            100,
            200,
            255,     // Max unsigned byte
            256,     // Byte overflow
            1000,
            1024,    // Power of 2

            // Values useful for divisibility tests
            77,      // 7 * 11
            1155,    // 3 * 5 * 7 * 11, in range [1001, 1999]

            // Large values
            1_000_000,
            -1_000_000,
        ]
    }

    public func mutate() -> [Int] {
        var mutations: [Int] = []

        // Basic arithmetic mutations (with overflow protection)
        if self != Int.max { mutations.append(self + 1) }
        if self != Int.min { mutations.append(self - 1) }
        if self != 0 && self != Int.min { mutations.append(-self) }  // -Int.min overflows
        if self != 0 { mutations.append(self / 2) }
        if self > 0 && self <= Int.max / 2 { mutations.append(self * 2) }
        if self < 0 && self >= Int.min / 2 { mutations.append(self * 2) }

        // Bit manipulation
        if self != 0 { mutations.append(self ^ 1) }  // Flip LSB

        // Divisibility-aware mutations: try nearby multiples of common factors
        for factor in [7, 11, 13, 77] {
            let nearestMultiple = (self / factor) * factor
            if nearestMultiple != self && nearestMultiple != 0 {
                mutations.append(nearestMultiple)
            }
            // Also try the next multiple up
            let (next, overflow) = nearestMultiple.addingReportingOverflow(factor)
            if !overflow && next != self {
                mutations.append(next)
            }
        }

        return mutations
    }
}
