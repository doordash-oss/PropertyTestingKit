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

import Clocks
import Dependencies
import Foundation
import Testing
@testable import PropertyTestingKit
@testable import ScheduleControl

/// Guards the flattened-pack schedule design: schedule fuzzing runs the engine
/// over the extended pack `([UInt8], repeat each UserInput)`, but the user's test
/// and the returned result must see only the user's own inputs, with the schedule
/// bytes surfaced separately via `entry.scheduleBytes`.
@Suite("Flattened Schedule Pack")
struct FlattenedScheduleTests {

    private struct PeelTestError: Error {}

    /// Deterministic contract test for `peelScheduleResult` — no scheduling, no
    /// timing, so it is robust under parallel test execution. Builds a result over
    /// the extended pack `([UInt8], Int, String)` and verifies the peel moves
    /// element 0 onto `scheduleBytes` while leaving the user's `(Int, String)`
    /// input intact, for both corpus entries and failures.
    @Test("peelScheduleResult moves element 0 to scheduleBytes and keeps the user input")
    func peelMovesElementZeroToScheduleBytes() throws {
        let entry = CorpusEntry<[UInt8], Int, String>(
            input: [9, 8, 7], 42, "hi",
            scheduleBytes: nil,
            sparseCoverage: SparseCoverage(indices: [1, 2]),
            entryType: .coverage,
            failure: nil
        )
        let extended = FuzzResult<[UInt8], Int, String>(
            corpus: CorpusSnapshot(entries: [entry], coveredIndices: [1, 2]),
            failures: [(input: ([5, 6], 7, "bye"), error: PeelTestError(), timeElapsed: 0.25)],
            stats: FuzzStats(totalInputs: 1, mutations: 0, generations: 1, duration: 0.5),
            wasRegression: false
        )

        let peeled = peelScheduleResult(extended)

        // Corpus entry: input peeled to (Int, String), schedule bytes surfaced.
        try #require(peeled.corpus.entries.count == 1)
        let e = peeled.corpus.entries[0]
        let (ei, es) = e.input
        #expect(ei == 42)
        #expect(es == "hi")
        #expect(e.scheduleBytes == [9, 8, 7])
        #expect(e.sparseCoverage.indices == [1, 2])
        #expect(peeled.corpus.coveredIndices == [1, 2])

        // Failure: input peeled to (Int, String); schedule bytes are not carried
        // in the failures tuple (there is no slot), matching the prior behavior.
        try #require(peeled.failures.count == 1)
        #expect(peeled.failures[0].input.0 == 7)
        #expect(peeled.failures[0].input.1 == "bye")
        #expect(peeled.failures[0].error is PeelTestError)

        #expect(peeled.stats.totalInputs == 1)
        #expect(peeled.wasRegression == false)
    }

    /// Integration smoke: a scheduled fuzz over a multi-element pack `(Int, String)`
    /// exercises the peel end-to-end through the engine. The user closure is typed
    /// `(Int, String)`, so a leaked `[UInt8]` schedule element would be a compile
    /// error; any entries produced must carry length-preserved schedule bytes and
    /// a `(Int, String)` input. Under heavy parallel load the scheduled run can be
    /// starved to zero iterations (as the other scheduled tests tolerate), so this
    /// asserts the per-entry contract only when entries are produced.
    @Test("Scheduled fuzz over a multi-element pack peels correctly", .timeLimit(.minutes(1)))
    func scheduledFuzzMultiElementPeel() async throws {
        try await withDependencies {
            $0.continuousClock = ImmediateClock()
        } operation: {
            let result = try await fuzz(
                using: Mutator<Int>(seeds: [1, 2, 3], mutate: { [$0 &+ 1, $0 &- 1] }),
                       Mutator<String>(seeds: ["a", "bb"], mutate: { [$0 + "x"] }),
                duration: .milliseconds(200),
                persistence: .replace,
                scheduleFuzzing: true
            ) { (i: Int, s: String) in
                await withTaskGroup(of: Int.self) { group in
                    group.addTask { i }
                    group.addTask { s.count }
                    for await _ in group {}
                }
            }

            for entry in result.corpus.entries {
                #expect(
                    entry.scheduleBytes?.count == ScheduleByteMutator.defaultLength,
                    "schedule bytes should be present and length-preserving"
                )
                // Compile-enforced peel: destructuring would fail to build if the
                // [UInt8] schedule element leaked into the user pack.
                let (_, _): (Int, String) = entry.input
            }
        }
    }
}
