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

//  End-to-end input-to-state test. This target is built with
//  `-sanitize-coverage=…,trace-cmp`, so the `==` comparison in the SUT below
//  fires a real comparison hook. With PTK_INPUT_TO_STATE the engine attaches a
//  comparison observer that feeds the operands into a ComparisonDictionary the
//  Int mutator samples from, so the fuzzer jumps straight to the magic constant
//  — a bug that random search over a 64-bit space would essentially never hit.
//

import Testing
import Foundation
@testable import PropertyTestingKit

/// A magic-value bug: `false` (the property fails) exactly when `x` equals the
/// constant. The `==` is instrumented (trace-cmp), so each execution reports
/// `(x, magicConstant)` to the I2S dictionary. `@inline(never)` keeps it a
/// distinct comparison site.
private let magicConstant = 0x5EED_CAFE_1357

@inline(never)
private func magicValueHolds(_ x: Int) -> Bool {
    x != magicConstant
}

@Suite("Fuzzing input-to-state")
struct FuzzInputToStateTests {

    /// Runs one fuzz campaign over the magic-value SUT, returning whether the
    /// bug was found within the budget. I2S is enabled via the task-local —
    /// bound only in this call's task tree, so parallel tests never race on it.
    private func campaignFindsMagic(inputToState: Bool) async throws -> Bool {
        let found = PropertyTestingKit.SyncBox<Bool>(false)
        try await ComparisonDictionary.$inputToStateEnabled.withValue(inputToState) {
            _ = try await fuzz(
                duration: .seconds(3),
                persistence: .ephemeral,
                parallelism: 1
            ) { (x: Int) in
                if !magicValueHolds(x) { found.update { $0 = true } }
            }
        }
        return found.value
    }

    /// Both phases in one test so the I2S task-local is bound and torn down
    /// sequentially — no inter-test interference. With I2S the comparison
    /// operand feeds the dictionary and the Int mutator jumps to the constant;
    /// without it, random search over a ~10^14 space cannot stumble onto it.
    @Test("I2S reaches a magic-value bug that random search cannot")
    func inputToStateReachesMagicConstant() async throws {
        let foundWithI2S = try await campaignFindsMagic(inputToState: true)
        #expect(foundWithI2S,
                "with I2S the Int mutator jumps to the learned comparison operand")

        let foundWithout = try await campaignFindsMagic(inputToState: false)
        #expect(!foundWithout,
                "without I2S, random mutation must not conjure a ~10^14 constant")
    }
}
