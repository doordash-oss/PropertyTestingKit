//
//  Optional+Fuzzable.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

extension Optional: Fuzzable where Wrapped: Fuzzable {
    public static var fuzz: [Optional<Wrapped>] {
        [nil] + Wrapped.fuzz.map { .some($0) }
    }

    public func mutate() -> [Optional<Wrapped>] {
        switch self {
        case .none:
            return Wrapped.fuzz.map { .some($0) }
        case .some(let wrapped):
            return [nil] + wrapped.mutate().map { .some($0) }
        }
    }
}
