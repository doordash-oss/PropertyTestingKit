//
//  Character+Fuzzable.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Foundation

extension Character: Fuzzable {
    public static var fuzz: [Character] {
        ["a", "Z", "0", " ", "\n", "\t", "😄", "\0"]
    }

    public func mutate() -> [Character] {
        Self.fuzz.filter { $0 != self }
    }
}
