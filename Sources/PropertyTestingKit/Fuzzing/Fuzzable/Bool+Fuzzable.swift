//
//  Bool+Fuzzable.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

extension Bool: Fuzzable {
    public static var fuzz: [Bool] {
        [true, false]
    }

    public func mutate() -> [Bool] {
        [!self]
    }
}
