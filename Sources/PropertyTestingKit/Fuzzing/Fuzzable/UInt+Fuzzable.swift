//
//  UInt+Fuzzable.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

extension UInt: Fuzzable {
    public static var fuzz: [UInt] {
        [0, 1, UInt.max, UInt.max / 2, 42, 100, 1000]
    }

    public func mutate() -> [UInt] {
        var mutations: [UInt] = []
        if self != UInt.max { mutations.append(self + 1) }
        if self != 0 { mutations.append(self - 1) }
        if self != 0 { mutations.append(self / 2) }
        if self != 0 && self <= UInt.max / 2 { mutations.append(self * 2) }  // 0 * 2 = 0
        return mutations
    }
}
