//
//  Double+MutatorProviding.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Dependencies
import Foundation

extension Double: MutatorProviding {
    public static var defaultMutator: AnyMutator<Double> {
        @Dependency(\.random) var random
        return AnyMutator(
            seeds: [
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
            ],
            mutate: { value in
                guard value.isFinite else { return [0.0, 1.0, -1.0] }

                var mutations: [Double] = []
                mutations.append(value + 1)
                mutations.append(value - 1)
                mutations.append(-value)
                if value != 0 { mutations.append(value / 2) }
                mutations.append(value * 2)
                mutations.append(value + 0.1)
                mutations.append(value - 0.1)
                return mutations
            },
            generate: {
                random { rng in
                    // Mix of strategies for interesting random double generation
                    let strategy = Int.random(in: 0..<10, using: &rng)
                    switch strategy {
                    case 0:
                        // Zero
                        return 0.0
                    case 1:
                        // Small range [-1, 1]
                        return Double.random(in: -1.0...1.0, using: &rng)
                    case 2:
                        // Percentage range [0, 1]
                        return Double.random(in: 0.0...1.0, using: &rng)
                    case 3:
                        // Medium range [-1000, 1000]
                        return Double.random(in: -1000.0...1000.0, using: &rng)
                    case 4:
                        // Large range
                        return Double.random(in: -1_000_000.0...1_000_000.0, using: &rng)
                    case 5:
                        // Very small positive values
                        return Double.random(in: Double.leastNormalMagnitude...0.001, using: &rng)
                    case 6:
                        // Integer-like doubles
                        return Double(Int.random(in: -1000...1000, using: &rng))
                    case 7:
                        // Powers of 2
                        let power = Int.random(in: -10...10, using: &rng)
                        return pow(2.0, Double(power))
                    case 8:
                        // Special values (rarely)
                        let specials: [Double] = [.nan, .infinity, -.infinity, .pi, .ulpOfOne]
                        return specials.randomElement(using: &rng) ?? 0.0
                    default:
                        // Near common values with small offset
                        let bases: [Double] = [0.0, 1.0, -1.0, 0.5, 100.0, -100.0]
                        let base = bases.randomElement(using: &rng) ?? 0.0
                        let offset = Double.random(in: -0.1...0.1, using: &rng)
                        return base + offset
                    }
                }
            }
        )
    }
}
