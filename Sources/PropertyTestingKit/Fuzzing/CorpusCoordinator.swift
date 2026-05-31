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

//  Corpus-mode coordination: the policy layer around the (mode-agnostic) FuzzEngine.
//
//  `FuzzEngine` is a pure fuzz runner — it builds an in-memory corpus and returns it.
//  Everything about corpus *policy* lives here: resolving the `CorpusMode`, loading and
//  saving the on-disk corpus, regression replay, and parallel orchestration with result
//  merging. Regression is unified with fuzzing: the corpus is loaded into the seed list
//  and the run is terminated by the `stopWhenQueueEmpty()` plugin once those seeds drain.
//

import Foundation
import Testing
import Dependencies

// MARK: - Seed assembly

/// The seed inputs derived from a tuple of mutators' `seeds` values.
///
/// Expands to the cartesian product where each position varies over its mutator's seeds
/// while the others are held at their first seed. The engine no longer derives these
/// itself — callers assemble the seed list (these plus any domain-specific inputs).
func mutatorSeeds<each Input: Codable & Sendable>(
    _ mutators: (repeat Mutator<each Input>)
) -> [(repeat each Input)] {
    var inputSize = 0
    (repeat { _ = each mutators; inputSize += 1 }())

    let positionsExpanded: [(repeat [each Input])] = (0..<inputSize).map { expandIndex in
        var currentIndex = 0
        return (repeat {
            defer { currentIndex += 1 }
            let seeds = (each mutators).seeds
            if currentIndex == expandIndex {
                return seeds
            } else {
                return [seeds[0]]
            }
        }())
    }
    return positionsExpanded.flatMap(cartesianProduct)
}

// MARK: - Campaign entry point

/// Run a complete fuzz campaign for the given corpus mode.
///
/// This is the single place that decides — based on `mode` and whether a corpus already
/// exists — whether to replay (regression) or fuzz, loads/saves the corpus, and fans out
/// across parallel engines when fuzzing. The engine itself sees none of this.
@usableFromInline
func runFuzzCampaign<each Input: Codable & Sendable>(
    mutators: (repeat Mutator<each Input>),
    userSeeds: [(repeat each Input)],
    corpusDir: URL,
    mode: CorpusMode,
    parallelism: Int,
    duration: Duration,
    verbose: Bool,
    coverageStrategy: CoverageStrategyKind,
    edgeHook: EdgeHook?,
    projectPath: String?,
    sourceFileID: String,
    sourceFilePath: String,
    line: Int,
    makeHandlers: @escaping @Sendable () -> [FuzzPluginHandler<repeat each Input>],
    test: @escaping @Sendable ((repeat each Input)) async throws -> Void
) async -> FuzzResult<repeat each Input> {
    @Dependency(\.corpusPersistence) var corpusPersistence

    func config(strategy: CoverageStrategyKind) -> FuzzEngineConfig {
        FuzzEngineConfig(
            maxDuration: duration,
            verbose: verbose,
            projectPath: projectPath,
            coverageStrategy: strategy,
            edgeHook: edgeHook,
            fileID: sourceFileID,
            filePath: sourceFilePath,
            line: line,
            column: 1
        )
    }

    func loadSnapshot() -> CorpusSnapshot<repeat each Input>? {
        do {
            return try corpusPersistence.loadSnapshot(from: corpusDir)
        } catch {
            if verbose {
                print("[Fuzz] Failed to load corpus: \(error)")
            }
            return nil
        }
    }

    let corpusExists = corpusPersistence.exists(corpusDir)

    switch mode {
    case .regressionOnly:
        guard corpusExists, let snapshot = loadSnapshot() else {
            if verbose {
                print("[Fuzz] Mode: regressionOnly - no corpus to regress")
            }
            return .empty
        }
        return await replayRegression(
            snapshot: snapshot,
            mutators: mutators,
            config: config(strategy: .alwaysInteresting),
            makeHandlers: makeHandlers,
            test: test
        )

    case .auto:
        // Regression if a corpus exists and loads; otherwise fall through to fuzzing.
        if corpusExists, let snapshot = loadSnapshot() {
            return await replayRegression(
                snapshot: snapshot,
                mutators: mutators,
                config: config(strategy: .alwaysInteresting),
                makeHandlers: makeHandlers,
                test: test
            )
        }
        return await fuzzAndSave(
            mutators: mutators,
            seeds: userSeeds,
            corpusDir: corpusDir,
            parallelism: parallelism,
            verbose: verbose,
            config: config(strategy: coverageStrategy),
            makeHandlers: makeHandlers,
            test: test
        )

    case .refuzzReplace:
        if corpusExists {
            if verbose {
                print("[Fuzz] Mode: refuzzReplace - deleting existing corpus")
            }
            try? corpusPersistence.delete(corpusDir)
        }
        return await fuzzAndSave(
            mutators: mutators,
            seeds: userSeeds,
            corpusDir: corpusDir,
            parallelism: parallelism,
            verbose: verbose,
            config: config(strategy: coverageStrategy),
            makeHandlers: makeHandlers,
            test: test
        )

    case .refuzzExtend:
        var seeds = userSeeds
        if corpusExists, let snapshot = loadSnapshot() {
            if verbose {
                print("[Fuzz] Mode: refuzzExtend - loaded \(snapshot.count) corpus entries as seeds")
            }
            seeds.append(contentsOf: snapshot.entries.map(\.input))
        }
        return await fuzzAndSave(
            mutators: mutators,
            seeds: seeds,
            corpusDir: corpusDir,
            parallelism: parallelism,
            verbose: verbose,
            config: config(strategy: coverageStrategy),
            makeHandlers: makeHandlers,
            test: test
        )
    }
}

// MARK: - Regression replay

/// Replay a saved corpus by seeding the engine with it and stopping when the queue drains.
///
/// The corpus inputs are the engine's only seeds (no mutator seed values are mixed in), so
/// exactly the saved inputs run. The sync plugin path is
/// just `stopWhenQueueEmpty()` — it terminates the run the instant the seeds are exhausted
/// and never lets corpus-mutation refill the queue. The async path keeps the user's handlers
/// so analysis (`coverageGap` at `.end`, `shrinking` on failures) still runs. The returned
/// corpus is the loaded snapshot (unchanged, not re-saved); coverage is measured via the
/// `.alwaysInteresting` strategy so `.end` sees the union over every replayed input.
private func replayRegression<each Input: Codable & Sendable>(
    snapshot: CorpusSnapshot<repeat each Input>,
    mutators: (repeat Mutator<each Input>),
    config: FuzzEngineConfig,
    makeHandlers: @escaping @Sendable () -> [FuzzPluginHandler<repeat each Input>],
    test: @escaping @Sendable ((repeat each Input)) async throws -> Void
) async -> FuzzResult<repeat each Input> {
    let corpusInputs = snapshot.entries.map(\.input)

    let syncProcessor = PluginHandlerProcessor<repeat each Input>(
        handlers: [.stopWhenQueueEmpty()]
    )
    let asyncProcessor = PluginHandlerProcessor<repeat each Input>(handlers: makeHandlers())

    // Replay exactly the saved corpus — no mutator seed values are mixed in.
    let engine = FuzzEngine<repeat each Input>(mutators: mutators, config: config)
    let raw = await engine.run(
        seeds: corpusInputs,
        processSyncPlugins: { syncProcessor.processSync(event: $0, execute: $1) },
        processAsyncPlugins: { await asyncProcessor.processAsync(isolation: $0, event: $1, execute: $2) },
        test: test
    )

    // Surface the loaded snapshot (the on-disk corpus is authoritative and unchanged);
    // keep the replay's failures and stats. Flag the run as a regression.
    return FuzzResult(
        corpus: snapshot,
        failures: raw.failures,
        stats: raw.stats,
        wasRegression: true
    )
}

// MARK: - Fuzzing (single + parallel) with persistence

/// Run fuzzing (single-engine or N parallel engines) and persist the resulting corpus.
private func fuzzAndSave<each Input: Codable & Sendable>(
    mutators: (repeat Mutator<each Input>),
    seeds: [(repeat each Input)],
    corpusDir: URL,
    parallelism: Int,
    verbose: Bool,
    config: FuzzEngineConfig,
    makeHandlers: @escaping @Sendable () -> [FuzzPluginHandler<repeat each Input>],
    test: @escaping @Sendable ((repeat each Input)) async throws -> Void
) async -> FuzzResult<repeat each Input> {
    @Dependency(\.corpusPersistence) var corpusPersistence

    // The engine no longer injects seeds itself: the mutators' seed values are part of
    // the fuzz seed list, assembled here alongside the caller's seeds.
    let baseSeeds = mutatorSeeds(mutators)

    let result: FuzzResult<repeat each Input>
    if parallelism <= 1 {
        result = await runSingleEngine(
            mutators: mutators,
            seeds: baseSeeds + seeds,
            config: config,
            handlers: makeHandlers(),
            test: test
        )
    } else {
        if verbose {
            print("[Fuzz] Running \(parallelism) parallel fuzz engines")
        }
        result = await runParallelEngines(
            mutators: mutators,
            seeds: seeds,
            perEngineSeeds: baseSeeds,
            parallelism: parallelism,
            verbose: verbose,
            config: config,
            makeHandlers: makeHandlers,
            test: test
        )
    }

    // Persist only a non-empty corpus, so a refuzz that finds nothing leaves no stale file.
    if !result.corpus.entries.isEmpty {
        do {
            try corpusPersistence.save(result.corpus, to: corpusDir)
            if verbose {
                print("[Fuzz] Saved corpus to \(corpusDir.path)")
            }
        } catch {
            if verbose {
                print("[Fuzz] Failed to save corpus: \(error)")
            }
        }
    }

    return result
}

/// Run one engine with a single plugin processor shared across sync and async events.
private func runSingleEngine<each Input: Codable & Sendable>(
    mutators: (repeat Mutator<each Input>),
    seeds: [(repeat each Input)],
    config: FuzzEngineConfig,
    handlers: [FuzzPluginHandler<repeat each Input>],
    test: @escaping @Sendable ((repeat each Input)) async throws -> Void
) async -> FuzzResult<repeat each Input> {
    let processor = PluginHandlerProcessor<repeat each Input>(handlers: handlers)
    let engine = FuzzEngine<repeat each Input>(mutators: mutators, config: config)
    return await engine.run(
        seeds: seeds,
        processSyncPlugins: { processor.processSync(event: $0, execute: $1) },
        processAsyncPlugins: { await processor.processAsync(isolation: $0, event: $1, execute: $2) },
        test: test
    )
}

/// Run N independent engines, then merge. The round-robin-split `seeds` are distributed
/// one share per engine; `perEngineSeeds` (the mutators' seed values) are given to every
/// engine so each explores from the same starting points.
///
/// Each engine builds its own handler instances via `makeHandlers()` — handlers must never
/// be shared across engines. Engines never persist; the merged corpus is saved by the caller.
private func runParallelEngines<each Input: Codable & Sendable>(
    mutators: (repeat Mutator<each Input>),
    seeds: [(repeat each Input)],
    perEngineSeeds: [(repeat each Input)],
    parallelism: Int,
    verbose: Bool,
    config: FuzzEngineConfig,
    makeHandlers: @escaping @Sendable () -> [FuzzPluginHandler<repeat each Input>],
    test: @escaping @Sendable ((repeat each Input)) async throws -> Void
) async -> FuzzResult<repeat each Input> {
    var distributedSeeds: [[(repeat each Input)]] = Array(repeating: [], count: parallelism)
    for (index, seed) in seeds.enumerated() {
        distributedSeeds[index % parallelism].append(seed)
    }

    let results = await withTaskGroup(of: FuzzResult<repeat each Input>.self) { group in
        for engineIndex in 0..<parallelism {
            let engineSeeds = perEngineSeeds + distributedSeeds[engineIndex]
            group.addTask {
                await runSingleEngine(
                    mutators: mutators,
                    seeds: engineSeeds,
                    config: config,
                    handlers: makeHandlers(),
                    test: test
                )
            }
        }

        var allResults: [FuzzResult<repeat each Input>] = []
        for await result in group {
            allResults.append(result)
        }
        return allResults
    }

    return await mergeResults(results, verbose: verbose)
}

// MARK: - Result Merging

/// Merges results from multiple parallel fuzz engines.
private func mergeResults<each Input: Codable & Sendable>(
    _ results: [FuzzResult<repeat each Input>],
    verbose: Bool
) async -> FuzzResult<repeat each Input> {
    guard let first = results.first else {
        return .empty
    }

    guard results.count > 1 else {
        return first
    }

    // Merge all failures
    var allFailures: [(input: (repeat each Input), error: Error, timeElapsed: TimeInterval)] = []
    for result in results {
        allFailures.append(contentsOf: result.failures)
    }

    // Merge corpus: combine all entries, deduplicate by coverage
    // Note: Use explicit closures instead of keypaths to avoid Swift runtime crashes with parameter packs
    let mergedCorpus = mergeCorpusSnapshots(results.map { $0.corpus })

    // Merge stats: sum counts, take max duration
    let totalInputs = results.reduce(0) { $0 + $1.stats.totalInputs }
    let totalMutations = results.reduce(0) { $0 + $1.stats.mutations }
    let totalGenerations = results.reduce(0) { $0 + $1.stats.generations }
    let maxDuration = results.map { $0.stats.duration }.max() ?? 0

    // Determine stop reason - use timeLimit if any engine hit it
    let stopReason: FuzzStats.StopReason = results.contains { $0.stats.stopReason == .timeLimit }
        ? .timeLimit
        : (results.first?.stats.stopReason ?? .timeLimit)

    // Check if any was a regression run
    let wasRegression = results.contains { $0.wasRegression }

    let mergedStats = FuzzStats(
        totalInputs: totalInputs,
        mutations: totalMutations,
        generations: totalGenerations,
        duration: maxDuration,
        stopReason: stopReason,
        failures: allFailures.count
    )

    if verbose {
        print("[Fuzz] Merged \(results.count) engines: \(totalInputs) total inputs, \(allFailures.count) failures")
    }

    return FuzzResult(
        corpus: mergedCorpus,
        failures: allFailures,
        stats: mergedStats,
        wasRegression: wasRegression
    )
}

/// Merges multiple corpus snapshots into one, combining coverage.
private func mergeCorpusSnapshots<each Input: Codable & Sendable>(
    _ snapshots: [CorpusSnapshot<repeat each Input>]
) -> CorpusSnapshot<repeat each Input> {
    @Dependency(\.corpusRegistry) var corpusRegistry

    guard let first = snapshots.first else {
        return CorpusSnapshot<repeat each Input>(
            entries: [],
            coveredIndices: []
        )
    }

    guard snapshots.count > 1 else {
        return first
    }

    // Create a temporary corpus to deduplicate entries
    let mergedCorpus: Corpus<repeat each Input> = corpusRegistry.getCorpus()

    // Use a local signature hash set for deduplication
    var signatureHashes = Set<Int>()

    // Add all entries - addIfInteresting handles deduplication by coverage
    for snapshot in snapshots {
        for entry in snapshot.entries {
            _ = mergedCorpus.addIfInteresting(input: entry.input, sparse: entry.sparseCoverage, signatureHashes: &signatureHashes)
        }
    }

    return mergedCorpus.snapshot()
}
