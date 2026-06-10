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

//  FuzzStats counts inputs by where they came from: seed inputs, mutated
//  inputs, and fresh generations — all in executed-input units, so the
//  three always sum to totalInputs.

import Testing
import Foundation
@testable import PropertyTestingKit

@Suite("FuzzStats Accounting")
struct FuzzStatsAccountingTests {

    @Test("should_sum_seeds_mutations_generations_to_totalInputs")
    func accountingIdentityHolds() async throws {
        let result = try await fuzz(
            duration: .seconds(0.2),
            persistence: .ephemeral,
            parallelism: 1
        ) { (_: Int) in
            // Trivial passing body — we only care about the stats.
        }

        #expect(
            result.stats.seeds + result.stats.mutations + result.stats.generations
                == result.stats.totalInputs,
            "seeds(\(result.stats.seeds)) + mutations(\(result.stats.mutations)) + generations(\(result.stats.generations)) != totalInputs(\(result.stats.totalInputs))"
        )
    }

    @Test("should_count_all_mutator_seeds_as_seeds_run")
    func seedsRunMatchesMutatorSeedCount() async throws {
        // Int's default mutator ships 21 seed values; a single-element pack's
        // seed list is exactly those. 0.2s of a trivial body runs thousands of
        // iterations, so every seed is consumed.
        let expectedSeeds = Int.defaultMutator.seeds.count

        let result = try await fuzz(
            duration: .seconds(0.2),
            persistence: .ephemeral,
            parallelism: 1
        ) { (_: Int) in }

        #expect(result.stats.seeds == expectedSeeds,
                "expected \(expectedSeeds) seed inputs run, got \(result.stats.seeds)")
    }

    @Test("should_count_mutated_inputs_run_not_mutation_batches")
    func mutationsCountedInExecutedInputUnits() async throws {
        let result = try await fuzz(
            duration: .seconds(0.2),
            persistence: .ephemeral,
            parallelism: 1
        ) { (_: Int) in }

        // A trivially-passing Int fuzz mutates constantly. If `mutations` were
        // counting selection events (batches) it would be ~15x smaller than the
        // executed-mutant count; the accounting identity in the first test pins
        // the exact value — here we just require it to dominate generations,
        // which is the signature of executed-input units.
        #expect(result.stats.mutations > result.stats.generations,
                "mutations(\(result.stats.mutations)) should dominate generations(\(result.stats.generations)) for a trivial body")
    }
}
