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

        // Seeds are consumed before any mutation/generation, so the count is
        // exactly the seed list — UNLESS the engine was starved (cooperative
        // pool saturated under the full parallel suite) and ran fewer total
        // inputs than there are seeds. Bounding by totalInputs keeps the
        // contract precise without flaking on starvation.
        #expect(result.stats.seeds == min(expectedSeeds, result.stats.totalInputs),
                "expected \(min(expectedSeeds, result.stats.totalInputs)) seed inputs run (min of \(expectedSeeds) seeds and \(result.stats.totalInputs) total), got \(result.stats.seeds)")
    }

    @Test("should_count_mutated_inputs_run_not_mutation_batches")
    func mutationsCountedInExecutedInputUnits() async throws {
        let seedCount = Int.defaultMutator.seeds.count
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
        //
        // This only holds once the engine has run past the seed phase. Under a
        // saturated cooperative pool (full parallel suite) it can be starved to
        // fewer inputs than there are seeds, in which case mutations==0 is
        // correct, not a regression — so we only assert dominance past seeds.
        try withKnownIssue("engine may be starved below the seed phase under full-suite oversubscription", isIntermittent: true) {
            #expect(result.stats.totalInputs > seedCount,
                    "expected the engine to run past the \(seedCount)-seed phase, ran \(result.stats.totalInputs) total")
        }
        if result.stats.totalInputs > seedCount {
            #expect(result.stats.mutations > result.stats.generations,
                    "mutations(\(result.stats.mutations)) should dominate generations(\(result.stats.generations)) for a trivial body")
        }
    }

    @Test("should_hold_accounting_identity_across_parallel_engines")
    func accountingIdentityHoldsInParallel() async throws {
        let result = try await fuzz(
            duration: .seconds(0.2),
            persistence: .ephemeral,
            parallelism: 4
        ) { (_: Int) in }

        #expect(
            result.stats.seeds + result.stats.mutations + result.stats.generations
                == result.stats.totalInputs,
            "merged stats must keep the identity: seeds(\(result.stats.seeds)) + mutations(\(result.stats.mutations)) + generations(\(result.stats.generations)) != totalInputs(\(result.stats.totalInputs))"
        )
    }

    @Test("should_hold_accounting_identity_under_schedule_fuzzing")
    func accountingIdentityHoldsWithScheduleFuzzing() async throws {
        let result = try await fuzz(
            duration: .seconds(0.2),
            persistence: .ephemeral,
            scheduleFuzzing: true
        ) { (_: Int) in }

        #expect(
            result.stats.seeds + result.stats.mutations + result.stats.generations
                == result.stats.totalInputs,
            "scheduled stats must keep the identity: seeds(\(result.stats.seeds)) + mutations(\(result.stats.mutations)) + generations(\(result.stats.generations)) != totalInputs(\(result.stats.totalInputs))"
        )
    }
}
