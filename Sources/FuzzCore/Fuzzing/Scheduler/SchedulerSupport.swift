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

//  Input-production primitives shared by schedulers. A scheduler owns *when* to
//  generate vs mutate (its policy); these are the *how* — pure functions over
//  the engine's mutators, reusable by any scheduler (the weighted pool, FOX,
//  custom). They moved here from the engine when input production became the
//  scheduler's responsibility.
//

/// Generate a fresh input: one generated value per pack position.
public func generateInput<each Input>(
    rng: inout FastRNG,
    mutators: repeat Mutator<each Input>
) -> (repeat each Input) {
    (repeat (each mutators).generate(&rng))
}

/// Mutate exactly `position` of the input pack with one mutator call, holding
/// every other position fixed.
public func mutateOnePosition<each Input>(
    _ input: (repeat each Input),
    position: Int,
    rng: inout FastRNG,
    mutators: repeat Mutator<each Input>
) -> (repeat each Input) {
    var currentIndex = 0
    return (repeat {
        defer { currentIndex += 1 }
        if currentIndex == position {
            return (each mutators).mutate(each input, &rng)
        } else {
            return (each input)
        }
    }())
}

/// Produce ONE mutant: a single mutation step at one randomly chosen position of
/// the input pack. A 0-arity pack has no position to mutate, so it is returned
/// unchanged rather than trapping on `Int.random(in: 0..<0)`.
public func mutateOneRandomPosition<each Input>(
    _ input: (repeat each Input),
    inputSize: Int,
    rng: inout FastRNG,
    mutators: repeat Mutator<each Input>
) -> (repeat each Input) {
    guard inputSize > 0 else { return input }
    let position = inputSize == 1 ? 0 : Int.random(in: 0..<inputSize, using: &rng)
    return mutateOnePosition(input, position: position, rng: &rng, mutators: repeat each mutators)
}

/// Chain the single-position mutator `depth` times (depth-d = mutate∘…∘mutate),
/// each step picking its own random position. `depth` clamps to ≥ 1, so a chain
/// is never a no-op pass-through; depth 1 reproduces the single-step mutant. A
/// depth policy (e.g. `AdaptiveDepthPolicy`) raises depth to push deeper into a
/// productive entry's neighbourhood; the weighted pool calls this in `next()`.
public func chainMutate<each Input>(
    _ input: (repeat each Input),
    depth: Int,
    inputSize: Int,
    rng: inout FastRNG,
    mutators: repeat Mutator<each Input>
) -> (repeat each Input) {
    var current = input
    for _ in 0..<max(1, depth) {
        current = mutateOneRandomPosition(
            current, inputSize: inputSize, rng: &rng, mutators: repeat each mutators)
    }
    return current
}
