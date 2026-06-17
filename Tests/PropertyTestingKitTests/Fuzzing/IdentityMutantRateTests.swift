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

//  Characterization tests that exercise every built-in mutator with a LIVE
//  RNG and measure how often `mutate(value, &rng)` returns a value equal to
//  its input — an "identity mutant".
//
//  Why this matters: since #41 a mutator returns exactly ONE value per call,
//  and the engine queues a fixed burst of those per selection. When a chosen
//  strategy collapses to the input (e.g. `port % 65536 == port`, `0.0 * 2`,
//  `"" + ""`), the whole mutant is wasted — it re-tests a known input and
//  produces no new coverage. In the old array-returning form an identity
//  element among many was harmless; now it can be the entire mutant.
//
//  These tests don't assert a hard budget (the rates are the deliverable);
//  they print a table and sanity-check that every mutator was exercised.

import Foundation
import Testing

@testable import PropertyTestingKit

@Suite("Identity-mutant rates (live RNG)")
struct IdentityMutantRateTests {

    /// One measured mutator.
    struct Row {
        let name: String
        let seedRate: Double      // identity fraction when mutating the mutator's own seeds
        let seedCalls: Int
        let genRate: Double       // identity fraction when mutating freshly generated values
        let genCalls: Int
    }

    /// Fraction of `mutate` calls that returned a value `==` the input, summed
    /// over every value in `values` repeated `trials` times against a live RNG.
    private func identityRate<V: Equatable>(
        _ mutator: Mutator<V>,
        over values: [V],
        trials: Int,
        rng: inout FastRNG
    ) -> (rate: Double, calls: Int) {
        guard !values.isEmpty, trials > 0 else { return (0, 0) }
        var identity = 0
        var calls = 0
        for value in values {
            for _ in 0..<trials {
                if mutator.mutate(value, &rng) == value { identity += 1 }
                calls += 1
            }
        }
        return (Double(identity) / Double(calls), calls)
    }

    /// Measure identity rate both over the mutator's declared seeds (the
    /// worst-case, hand-picked boundary values) and over its own generated
    /// distribution (what it actually emits during a fresh run).
    private func measure<V: Equatable>(
        _ name: String,
        _ mutator: Mutator<V>,
        trialsPerSeed: Int = 4000,
        generatedSamples: Int = 400,
        trialsPerGenerated: Int = 200,
        rng: inout FastRNG
    ) -> Row {
        let seed = identityRate(mutator, over: mutator.seeds, trials: trialsPerSeed, rng: &rng)
        let generated = (0..<generatedSamples).map { _ in mutator.generate(&rng) }
        let gen = identityRate(mutator, over: generated, trials: trialsPerGenerated, rng: &rng)
        return Row(
            name: name, seedRate: seed.rate, seedCalls: seed.calls,
            genRate: gen.rate, genCalls: gen.calls)
    }

    /// Build the full registry of built-in mutators. Each entry is measured at
    /// its concrete element type (Int where a type parameter is needed).
    private func allRows(rng: inout FastRNG) -> [Row] {
        var rows: [Row] = []

        // Scalars — MutatorProviding defaults
        rows.append(measure("Int.defaultMutator", Int.defaultMutator, rng: &rng))
        rows.append(measure("UInt.defaultMutator", UInt.defaultMutator, rng: &rng))
        rows.append(measure("UInt8.defaultMutator", UInt8.defaultMutator, rng: &rng))
        rows.append(measure("Double.defaultMutator", Double.defaultMutator, rng: &rng))
        rows.append(measure("Bool.defaultMutator", Bool.defaultMutator, rng: &rng))
        rows.append(measure("Character.defaultMutator", Character.defaultMutator, rng: &rng))
        rows.append(measure("String.defaultMutator", String.defaultMutator, rng: &rng))

        // Int named strategy sets
        rows.append(measure("Int.boundaries", Mutator<Int>.boundaries, rng: &rng))
        rows.append(measure("Int.ports", .ports, rng: &rng))
        rows.append(measure("Int.httpStatusCodes", .httpStatusCodes, rng: &rng))
        rows.append(measure("Int.negative", .negative, rng: &rng))
        rows.append(measure("Int.powers", .powers, rng: &rng))

        // Double named strategy sets
        rows.append(measure("Double.boundaries", Mutator<Double>.boundaries, rng: &rng))
        rows.append(measure("Double.special", .special, rng: &rng))
        rows.append(measure("Double.percentages", .percentages, rng: &rng))

        // String named strategy sets
        rows.append(measure("String.emails", .emails, rng: &rng))
        rows.append(measure("String.urls", .urls, rng: &rng))
        rows.append(measure("String.sql", .sql, rng: &rng))
        rows.append(measure("String.xss", .xss, rng: &rng))
        rows.append(measure("String.unicode", .unicode, rng: &rng))
        rows.append(measure("String.whitespace", .whitespace, rng: &rng))
        rows.append(measure("String.phoneNumbers", .phoneNumbers, rng: &rng))
        rows.append(measure("String.empty", .empty, rng: &rng))
        rows.append(measure("String.boundaries", Mutator<String>.boundaries, rng: &rng))

        // Array mutators (Element == Int)
        rows.append(measure("[Int].defaultMutator", [Int].defaultMutator, rng: &rng))
        rows.append(measure("arrayDuplicationMutator", arrayDuplicationMutator() as Mutator<[Int]>, rng: &rng))
        rows.append(measure("arrayLengthTargetedMutator", arrayLengthTargetedMutator() as Mutator<[Int]>, rng: &rng))
        rows.append(measure("arrayPositionAwareMutator", arrayPositionAwareMutator() as Mutator<[Int]>, rng: &rng))
        rows.append(measure("arrayRepeatedValuesMutator", arrayRepeatedValuesMutator() as Mutator<[Int]>, rng: &rng))
        rows.append(measure("arraySequenceInsertionMutator", arraySequenceInsertionMutator() as Mutator<[Int]>, rng: &rng))

        // Optional (Wrapped == Int)
        rows.append(measure("Optional<Int>.defaultMutator", Optional<Int>.defaultMutator, rng: &rng))

        return rows
    }

    @Test("Report identity-mutant rate for every built-in mutator")
    func reportIdentityMutantRates() {
        var rng = FastRNG()
        let rows = allRows(rng: &rng).sorted { $0.seedRate > $1.seedRate }

        func pct(_ x: Double) -> String {
            String(format: "%6.2f%%", x * 100)
        }

        func col(_ s: String) -> String { s.padding(toLength: 32, withPad: " ", startingAt: 0) }

        var table = "\n=== Identity-mutant rates (live RNG) ===\n"
        table += "\(col("mutator"))  seed-identity (calls)   gen-identity (calls)\n"
        for row in rows {
            table += "\(col(row.name))  \(pct(row.seedRate)) (\(row.seedCalls))   \(pct(row.genRate)) (\(row.genCalls))\n"
        }
        print(table)

        // Sanity: every mutator was actually exercised over both distributions.
        for row in rows {
            #expect(row.seedCalls > 0, "\(row.name) had no seeds to mutate")
            #expect(row.genCalls > 0, "\(row.name) generated no values to mutate")
        }
    }
}
