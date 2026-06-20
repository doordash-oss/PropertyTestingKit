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

//  A deterministic mock `RandomNumberGenerator` for tests. The production
//  `FastRNG` is backed by per-thread XorShift state and cannot be seeded, so
//  tests that assert on the *distribution* of weighted pool draws ride on
//  non-deterministic state and flake on near-ties. Injected via the
//  `\.poolDrawRNG` dependency to make those draws reproducible.
//

/// SplitMix64 — a fully deterministic `RandomNumberGenerator` whose output is
/// determined entirely by its seed. Well-distributed, so weighted sampling over
/// it still exercises the real draw distribution.
struct DeterministicRNG: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
