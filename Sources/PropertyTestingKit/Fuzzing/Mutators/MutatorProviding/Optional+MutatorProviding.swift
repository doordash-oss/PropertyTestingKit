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

import Dependencies

/// 1-in-N chance that mutating a `.some` flips it to `nil`. This exploration
/// bias is fixed in the mutator for now; longer term, how much effort to spend
/// on the nil branch is a scheduler decision (the same "effort belongs to the
/// caller" boundary as the engine's mutation burst length), not the mutator's.
private let optionalNilFlipDenominator = 5

extension Optional: MutatorProviding where Wrapped: MutatorProviding {
    public static var defaultMutator: Mutator<Optional<Wrapped>> {
        let wrappedMutator = Wrapped.defaultMutator

        return Mutator<Optional<Wrapped>>(
            seeds: [nil] + wrappedMutator.seeds.map { .some($0) },
            mutate: { value, rng in
                switch value {
                case .none:
                    // Wake up nil by picking a random wrapped seed
                    let seeds = wrappedMutator.seeds
                    guard !seeds.isEmpty else { return .some(wrappedMutator.generate(&rng)) }
                    return .some(seeds[Int.random(in: 0..<seeds.count, using: &rng)])
                case .some(let wrapped):
                    // Flip to nil with probability 1/optionalNilFlipDenominator,
                    // otherwise mutate the wrapped value.
                    if Int.random(in: 0..<optionalNilFlipDenominator, using: &rng) == 0 {
                        return nil
                    } else {
                        return .some(wrappedMutator.mutate(wrapped, &rng))
                    }
                }
            },
            generate: { rng in
                // 20% chance of nil, 80% chance of some value
                if Int.random(in: 0..<5, using: &rng) == 0 {
                    return nil
                } else {
                    return .some(wrappedMutator.generate(&rng))
                }
            }
        )
    }
}
