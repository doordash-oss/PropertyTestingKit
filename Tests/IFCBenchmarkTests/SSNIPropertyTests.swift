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

//  Property-based tests for the IFC machine, ported line-by-line from
//  QuickChick/IFC Driver.v, SSNI.v, and SanityChecks.v.
//
//  These tests use PropertyTestingKit's fuzz() API to perform
//  coverage-guided property-based testing of the IFC machine.
//

import Foundation
import Synchronization
import Testing
import IFCMachine
@testable import PropertyTestingKit

// MARK: - Ported from SanityChecks.v

/// prop_stamp_generation: well_formed st
///
/// From SanityChecks.v:
///   Definition prop_stamp_generation (st : State) : Checker :=
///     checker (well_formed st).
///
/// Every generated state must be well-formed:
/// - PC is within instruction bounds
/// - All pointer values point to valid memory addresses
/// - Register count matches expected count
@Suite("SanityChecks")
struct SanityCheckTests {

    @Test("Generated states are well-formed (prop_stamp_generation)")
    func propStampGeneration() async throws {
        try await fuzz(
            duration: .seconds(5),
            corpusMode: .refuzzReplace,

        ) { (state: MachineState) in
            #expect(wellFormed(state), "Generated state must be well-formed")
        }
    }

    @Test("Stepping preserves well-formedness (prop_fstep_preserves_well_formed)")
    func propFstepPreservesWellFormed() async throws {
        /// From SanityChecks.v:
        ///   if well_formed st then
        ///     match fstep t st with
        ///     | Some st' => checker (well_formed st')
        ///     | _ => checker rejected
        ///     end
        ///   else checker false
        try await fuzz(
            duration: .seconds(5),
            corpusMode: .refuzzReplace,

        ) { (state: MachineState) in
            guard wellFormed(state) else { return }
            switch step(state) {
            case .ok(let next):
                #expect(wellFormed(next), "Step must preserve well-formedness")
            case .halted, .error:
                break // discarded — not a counterexample
            }
        }
    }
}

// MARK: - Ported from SSNI.v

/// propSSNI_helper: the core SSNI property checker.
///
/// From SSNI.v:
///   if indist lab st1 st2 then
///     match fstep t st1 with
///     | Some st1' =>
///       if is_low_state st1 lab then
///         match fstep t st2 with
///         | Some st2' =>
///           collect "LOW -> *" (indist lab st1' st2')
///         | _ => collect "Second failed" (checker true)
///         end
///       else (* is_high st1 *)
///         if is_low_state st1' lab then
///           match fstep t st2 with
///           | Some st2' =>
///             if is_low_state st2' lab then
///               collect "HIGH -> LOW" (indist lab st1' st2')
///             else collect "Second not low" (checker true)
///           | _ => collect "Second failed H" (checker true)
///           end
///         else
///           collect "HIGH -> HIGH" (indist lab st1 st1')
///     | _ => collect "Failed" (checker true)
///     end
///   else collect "Not indist!" (checker true)
@Suite("SSNI Properties")
struct SSNIPropertyTests {

    /// propSSNI default_table
    ///
    /// From Driver.v:
    ///   QuickCheck (propSSNI default_table).
    @Test("SSNI holds for correct rule table (propSSNI default_table)")
    func propSSNICorrect() async throws {
        try await fuzz(
            duration: .seconds(10),
            corpusMode: .refuzzReplace,

        ) { (variation: Variation) in
            let result = propSSNIHelper(
                table: .correct,
                variation: variation
            )
            #expect(result == nil, "SSNI violation: \(result ?? "")")
        }
    }
}

// MARK: - Ported from Driver.v: MutateCheckMany

/// MutateCheckMany default_table (fun t => [propSSNI t; ...])
///
/// For each injected bug, SSNI should FAIL — the bug introduces a
/// noninterference violation that the fuzzer should find.
@Suite("Mutant Detection")
struct MutantDetectionTests {

    /// Test each bug variant: SSNI should be violated.
    /// Each test fuzzes with the buggy rule table and expects to find a violation.
    @Test("Fuzzer detects injected bug", arguments: IFCBug.allCases)
    func detectsBug(_ bug: IFCBug) async throws {
        let bugRules = bug.rules
        let foundAt = Mutex<Date?>(nil)
        let start = Date()

        let result = try await fuzz(
            duration: .seconds(60),
            corpusMode: .refuzzReplace,
            makeHandlers: { [.energyMutation()] }
        ) { (variation: Variation) in
            if foundAt.withLock({ $0 != nil }) { return }

            // propSSNI: check noninterference for both states in the variation
            if propSSNIHelper(table: bugRules, variation: variation) != nil {
                foundAt.withLock { if $0 == nil { $0 = Date() } }
                return
            }

            // prop_fstep_preserves_well_formed: check that stepping with the buggy
            // rule preserves well-formedness (from Coq Driver.v MutateCheckMany).
            for state in [variation.state1, variation.state2] {
                guard wellFormed(state) else { continue }
                if case .ok(let next) = step(state, rules: bugRules), !wellFormed(next) {
                    foundAt.withLock { if $0 == nil { $0 = Date() } }
                    return
                }
            }
        }

        let s = result.stats
        let mutPct = 100.0 * Double(s.totalInputs - s.generations) / Double(max(1, s.totalInputs))
        if let found = foundAt.withLock({ $0 }) {
            let elapsed = found.timeIntervalSince(start)
            print(String(format: "[FOUND]  \(bug.rawValue): found at %.2fs, %dk iters (%.0f%% from mutations, %.0f%% fresh), %.0f/s",
                         elapsed, s.totalInputs / 1000, mutPct, 100.0 - mutPct, s.inputsPerSecond))
        } else {
            print(String(format: "[MISSED] \(bug.rawValue): %dk iters (%.0f%% from mutations, %.0f%% fresh), %.0f/s",
                         s.totalInputs / 1000, mutPct, 100.0 - mutPct, s.inputsPerSecond))
            Issue.record("Fuzzer failed to detect SSNI violation for bug: \(bug.rawValue)")
        }
    }
}

