//
//  UInt8+Fuzzable.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

extension UInt8: Fuzzable {
    public static var fuzz: [UInt8] {
        [0, 1, 127, 128, 255, 42, 100]
    }

    public func mutate() -> [UInt8] {
        var mutations: [UInt8] = []
        if self != UInt8.max { mutations.append(self + 1) }
        if self != 0 { mutations.append(self - 1) }
        if self != 0 { mutations.append(self / 2) }
        if self != 0 && self <= UInt8.max / 2 { mutations.append(self * 2) }
        return mutations
    }
}
