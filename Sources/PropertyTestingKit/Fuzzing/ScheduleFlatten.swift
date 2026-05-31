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

import Foundation

// MARK: - Schedule-byte mutator

/// A `Mutator` over schedule bytes, used as the element-0 mutator of the
/// extended input pack when schedule fuzzing. Generation and mutation delegate
/// to `ScheduleByteMutator`, so schedule bytes are generated/mutated by the same
/// engine machinery as user inputs.
let scheduleByteMutator: Mutator<[UInt8]> = {
    var seedRng = FastRNG()
    return Mutator<[UInt8]>(
        seeds: [ScheduleByteMutator.generate(using: &seedRng)],
        mutate: { ScheduleByteMutator.mutate($0) },
        generate: { rng in ScheduleByteMutator.generate(using: &rng) }
    )
}()

// MARK: - Flattened-pack schedule fuzzing
//
// When schedule fuzzing is enabled, the engine runs over an *extended* input
// pack `([UInt8], repeat each Input)` whose leading element is the schedule
// bytes. This keeps the schedule bytes a first-class input element: generated,
// mutated, stored, and persisted by the same machinery as user inputs. The
// helpers here bridge between the user's pack `(repeat each Input)` and the
// engine's extended pack at the public boundary.

/// Strip the leading schedule-bytes element from an extended-pack fuzz result,
/// producing a result over the user's input pack `(repeat each Input)`.
///
/// Failures and corpus entries carry the extended tuple `([UInt8], repeat each
/// Input)`; this peels element 0 so callers never see the schedule bytes.
func peelScheduleResult<each Input: Codable & Sendable>(
    _ result: FuzzResult<[UInt8], repeat each Input>
) -> FuzzResult<repeat each Input> {
    let failures: [(input: (repeat each Input), error: Error, timeElapsed: TimeInterval)] =
        result.failures.map { failure in
            (input: (repeat each failure.input.1), error: failure.error, timeElapsed: failure.timeElapsed)
        }

    let entries: [CorpusEntry<repeat each Input>] = result.corpus.entries.map { entry in
        // Peel element 0 (the schedule bytes) out of the input pack and surface
        // it on the public `scheduleBytes` property, so callers see the user's
        // own input via `entry.input` and the schedule via `entry.scheduleBytes`,
        // exactly as before the flattening.
        CorpusEntry<repeat each Input>(
            input: repeat each entry.input.1,
            scheduleBytes: entry.input.0,
            sparseCoverage: entry.sparseCoverage,
            entryType: entry.entryType,
            failure: entry.failure
        )
    }

    return FuzzResult<repeat each Input>(
        corpus: CorpusSnapshot<repeat each Input>(
            entries: entries,
            coveredIndices: result.corpus.coveredIndices
        ),
        failures: failures,
        stats: result.stats,
        wasRegression: result.wasRegression
    )
}

/// Run schedule-fuzzing over the flattened pack `([UInt8], repeat each Input)`.
///
/// Delegates to the coordinator's `runFuzz` over the extended pack with the
/// schedule mutator prepended as element 0, so schedule bytes are generated,
/// mutated, stored, and persisted by the same persistence/parallelism machinery
/// as user inputs. The element-0 extractor (`{ $0.0 }`) is threaded to the engine
/// so each execution is wrapped in `ScheduleController.run`; the user's `test` is
/// invoked with only its own tail via a peel wrapper. The result is peeled back
/// to the user's pack, surfacing the schedule via `CorpusEntry.scheduleBytes`.
///
/// Schedule fuzzing forces a single engine (`parallelism: 1`): the schedule
/// controller installs a process-global task-enqueue hook that cannot be shared.
///
/// - Note: schedule fuzzing uses the default `corpusMutation` plugin behavior;
///   custom plugins are not applied to scheduled runs.
func runFlattenedSchedule<each Input: Codable & Sendable>(
    mutators: (repeat Mutator<each Input>),
    seeds: [(repeat each Input)],
    corpusDir: URL,
    persistence: CorpusPersistence,
    duration: Duration,
    verbose: Bool,
    coverageStrategy: CoverageStrategyKind,
    edgeHook: EdgeHook?,
    projectPath: String?,
    sourceFileID: String,
    sourceFilePath: String,
    line: Int,
    test: @escaping @Sendable ((repeat each Input)) async throws -> Void
) async -> FuzzResult<repeat each Input> {
    // Extend each user seed with a fresh random schedule as element 0.
    var seedRng = FastRNG()
    var extendedSeeds: [([UInt8], repeat each Input)] = []
    extendedSeeds.reserveCapacity(seeds.count)
    for seed in seeds {
        let bytes = ScheduleByteMutator.generate(using: &seedRng)
        extendedSeeds.append((bytes, repeat each seed))
    }

    // Peel wrapper: feed only the user's tail to the user's test.
    let peelTest: @Sendable (([UInt8], repeat each Input)) async throws -> Void = { extended in
        try await test((repeat each extended.1))
    }

    // Run over the extended pack through the coordinator. The schedule mutator is
    // prepended as element 0; the extractor reads it back to drive
    // `ScheduleController.run`. `scheduleFuzzing` stays off in the config — to the
    // engine, element 0 is just a normal input element.
    let extendedResult = await runFuzz(
        mutators: (scheduleByteMutator, repeat each mutators),
        userSeeds: extendedSeeds,
        corpusDir: corpusDir,
        persistence: persistence,
        parallelism: 1,
        duration: duration,
        verbose: verbose,
        coverageStrategy: coverageStrategy,
        edgeHook: edgeHook,
        scheduleFuzzing: false,
        projectPath: projectPath,
        sourceFileID: sourceFileID,
        sourceFilePath: sourceFilePath,
        line: line,
        scheduleBytesExtractor: { $0.0 },
        makeHandlers: { [.corpusMutation()] },
        test: peelTest
    )

    return peelScheduleResult(extendedResult)
}
