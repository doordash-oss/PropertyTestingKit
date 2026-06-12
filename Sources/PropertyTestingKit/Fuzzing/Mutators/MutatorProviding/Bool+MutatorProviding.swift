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

private let _boolSeeds: [Bool] = [true, false]

private func _boolMutate(_ value: Bool, _ rng: inout FastRNG) -> Bool {
    // The only meaningful mutation of a Bool is its negation.
    !value
}

private func _boolGenerate(_ rng: inout FastRNG) -> Bool {
    Bool.random(using: &rng)
}

extension Bool: MutatorProviding {
    public static let defaultMutator = Mutator<Bool>(
        seeds: _boolSeeds,
        mutate: _boolMutate,
        generate: _boolGenerate
    )
}
