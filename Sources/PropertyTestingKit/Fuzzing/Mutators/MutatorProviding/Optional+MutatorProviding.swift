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

extension Optional: MutatorProviding where Wrapped: MutatorProviding {
    public static var defaultMutator: Mutator<Optional<Wrapped>> {
        let wrappedMutator = Wrapped.defaultMutator

        return Mutator<Optional<Wrapped>>(
            seeds: [nil] + wrappedMutator.seeds.map { .some($0) },
            mutate: { value in
                switch value {
                case .none:
                    return wrappedMutator.seeds.map { .some($0) }
                case .some(let wrapped):
                    return [nil] + wrappedMutator.mutate(wrapped).map { .some($0) }
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
