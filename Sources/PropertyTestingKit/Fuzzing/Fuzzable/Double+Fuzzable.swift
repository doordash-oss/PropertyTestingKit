//
//  Double+Fuzzable.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

extension Double: Fuzzable {
    public static var fuzz: [Double] {
        [
            0.0,
            1.0,
            -1.0,
            0.5,
            -0.5,
            Double.greatestFiniteMagnitude,
            -Double.greatestFiniteMagnitude,
            Double.leastNormalMagnitude,
            Double.nan,
            Double.infinity,
            -Double.infinity,
        ]
    }

    public func mutate() -> [Double] {
        guard isFinite else { return [0.0, 1.0, -1.0] }

        var mutations: [Double] = []
        mutations.append(self + 1)
        mutations.append(self - 1)
        mutations.append(-self)
        if self != 0 { mutations.append(self / 2) }
        mutations.append(self * 2)
        mutations.append(self + 0.1)
        mutations.append(self - 0.1)
        return mutations
    }
}
