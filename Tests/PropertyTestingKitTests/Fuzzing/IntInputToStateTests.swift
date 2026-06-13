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

//  The framework's Int mutator consults ComparisonDictionary.current for
//  input-to-state mutation: when a dictionary is installed, mutation/generation
//  frequently jumps to a recorded comparison operand (or its ±1 neighbour, for
//  `<`/`<=` boundary bugs). With no dictionary it behaves exactly as before.
//

import Testing
@testable import PropertyTestingKit

@Suite("Int input-to-state mutation")
struct IntInputToStateTests {

    /// With a magic operand recorded and the dictionary installed, the Int
    /// mutator must reach that operand (or a ±1 neighbour) far more often than
    /// random search would — that is the whole point of I2S.
    @Test("Mutation jumps to a recorded operand when a dictionary is current")
    func mutationReachesRecordedOperand() {
        let dict = ComparisonDictionary()
        let magic = 0x0BADF00D
        dict.record(UInt64(magic))

        let targets: Set<Int> = [magic, magic + 1, magic - 1]
        var hits = 0
        ComparisonDictionary.$current.withValue(dict) {
            var rng = FastRNG()
            for _ in 0..<1000 {
                if targets.contains(Int.defaultMutator.mutate(0, &rng)) { hits += 1 }
            }
        }
        // Random mutation of 0 would essentially never produce 0x0BADF00D; I2S
        // should hit the operand neighbourhood a large fraction of the time.
        #expect(hits > 100, "I2S should reach the recorded operand frequently (got \(hits)/1000)")
    }

    @Test("Generation can produce a recorded operand when a dictionary is current")
    func generationReachesRecordedOperand() {
        let dict = ComparisonDictionary()
        let magic = 0x0BADF00D
        dict.record(UInt64(magic))

        let targets: Set<Int> = [magic, magic + 1, magic - 1]
        var hits = 0
        ComparisonDictionary.$current.withValue(dict) {
            var rng = FastRNG()
            for _ in 0..<1000 {
                if targets.contains(Int.defaultMutator.generate(&rng)) { hits += 1 }
            }
        }
        #expect(hits > 100, "I2S should generate the recorded operand frequently (got \(hits)/1000)")
    }

    /// No dictionary installed → never produces the magic value, and mutation
    /// still works normally (the I2S branch is inert).
    @Test("With no dictionary current, mutation is unaffected")
    func noDictionaryLeavesMutationUnchanged() {
        let magic = 0x0BADF00D
        var rng = FastRNG()
        var sawMagic = false
        for _ in 0..<1000 {
            let m = Int.defaultMutator.mutate(0, &rng)
            if m == magic { sawMagic = true }
        }
        #expect(ComparisonDictionary.current == nil)
        #expect(!sawMagic, "without I2S, mutating 0 must not conjure the magic constant")
    }
}
