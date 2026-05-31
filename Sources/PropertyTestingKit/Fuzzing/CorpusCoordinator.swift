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
//  Everything about corpus *policy* lives here: resolving the `CorpusPersistence` policy, loading and
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

// MARK: - Campaign entry points

private func loadSnapshot<each Input: Codable & Sendable>(
    from corpusDir: URL,
    verbose: Bool,
    scheduleFuzzing: Bool = false
) -> CorpusSnapshot<repeat each Input>? {
    @Dependency(\.corpusPersistence) var corpusPersistence
    do {
        return try corpusPersistence.loadSnapshot(from: corpusDir, scheduleFuzzing: scheduleFuzzing)
    } catch {
        if verbose {
            print("[Fuzz] Failed to load corpus: \(error)")
        }
        return nil
    }
}

/// Fuzz with the given persistence policy, then save the resulting corpus.
///
/// This is the `fuzz(...)` path. It decides — based on `persistence` and whether a corpus
/// already exists — whether to replay an existing corpus (`.auto` hit), delete-then-fuzz
/// (`.replace`), or load-as-seeds-then-fuzz (`.extend`), and fans out across parallel
/// engines. The engine itself sees none of this.
@usableFromInline
func runFuzz<each Input: Codable & Sendable>(
    mutators: (repeat Mutator<each Input>),
    userSeeds: [(repeat each Input)],
    corpusDir: URL,
    persistence: CorpusPersistence,
    parallelism: Int,
    duration: Duration,
    verbose: Bool,
    coverageStrategy: CoverageStrategyKind,
    edgeHook: EdgeHook?,
    scheduleFuzzing: Bool = false,
    projectPath: String?,
    sourceFileID: String,
    sourceFilePath: String,
    line: Int,
    scheduleBytesExtractor: @escaping @Sendable ((repeat each Input)) -> [UInt8]? = { _ in nil },
    makeHandlers: @escaping @Sendable () -> [FuzzPlugin<repeat each Input>],
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
            scheduleFuzzing: scheduleFuzzing,
            fileID: sourceFileID,
            filePath: sourceFilePath,
            line: line,
            column: 1
        )
    }

    switch persistence {
    case .auto:
        // Replay if a corpus exists and loads; otherwise fall through to fuzzing.
        // The replay is a pure verification: the fuzz plugins (which can emit write actions)
        // do not run during it — run `regress(...)` for replay-plus-analysis.
        if corpusPersistence.exists(corpusDir),
            let snapshot: CorpusSnapshot<repeat each Input> = loadSnapshot(from: corpusDir, verbose: verbose, scheduleFuzzing: scheduleFuzzing) {
            return await replayRegression(
                snapshot: snapshot,
                mutators: mutators,
                verbose: verbose,
                config: config(strategy: .alwaysInteresting),
                scheduleBytesExtractor: scheduleBytesExtractor,
                plugins: { [] },
                test: test
            )
        }
        return await fuzzCampaign(
            mutators: mutators,
            seeds: userSeeds,
            corpusDir: corpusDir,
            parallelism: parallelism,
            verbose: verbose,
            persist: true,
            config: config(strategy: coverageStrategy),
            scheduleBytesExtractor: scheduleBytesExtractor,
            makeHandlers: makeHandlers,
            test: test
        )

    case .replace:
        if corpusPersistence.exists(corpusDir) {
            if verbose {
                print("[Fuzz] persistence: replace - deleting existing corpus")
            }
            try? corpusPersistence.delete(corpusDir)
        }
        return await fuzzCampaign(
            mutators: mutators,
            seeds: userSeeds,
            corpusDir: corpusDir,
            parallelism: parallelism,
            verbose: verbose,
            persist: true,
            config: config(strategy: coverageStrategy),
            scheduleBytesExtractor: scheduleBytesExtractor,
            makeHandlers: makeHandlers,
            test: test
        )

    case .extend:
        var seeds = userSeeds
        if corpusPersistence.exists(corpusDir),
            let snapshot: CorpusSnapshot<repeat each Input> = loadSnapshot(from: corpusDir, verbose: verbose, scheduleFuzzing: scheduleFuzzing) {
            if verbose {
                print("[Fuzz] persistence: extend - loaded \(snapshot.count) corpus entries as seeds")
            }
            seeds.append(contentsOf: snapshot.entries.map(\.input))
        }
        return await fuzzCampaign(
            mutators: mutators,
            seeds: seeds,
            corpusDir: corpusDir,
            parallelism: parallelism,
            verbose: verbose,
            persist: true,
            config: config(strategy: coverageStrategy),
            scheduleBytesExtractor: scheduleBytesExtractor,
            makeHandlers: makeHandlers,
            test: test
        )

    case .ephemeral:
        // No persistence: ignore any existing corpus and never save. Nothing touches disk.
        return await fuzzCampaign(
            mutators: mutators,
            seeds: userSeeds,
            corpusDir: corpusDir,
            parallelism: parallelism,
            verbose: verbose,
            persist: false,
            config: config(strategy: coverageStrategy),
            scheduleBytesExtractor: scheduleBytesExtractor,
            makeHandlers: makeHandlers,
            test: test
        )
    }
}

/// Replay a saved corpus and verify it — the `regress(...)` path (and the env-forced
/// regression of a `fuzz(...)` call, which passes no handlers).
///
/// No corpus on disk → returns `.empty` without throwing, so a suite-wide replay over
/// not-yet-fuzzed tests doesn't fail. Coverage is measured via `.alwaysInteresting` so
/// `.end` sees the union over every replayed input. The corpus is never re-saved.
@usableFromInline
func runReplay<each Input: Codable & Sendable>(
    mutators: (repeat Mutator<each Input>),
    corpusDir: URL,
    duration: Duration,
    verbose: Bool,
    projectPath: String?,
    sourceFileID: String,
    sourceFilePath: String,
    line: Int,
    plugins: @escaping @Sendable () -> [AnalysisPlugin<repeat each Input>],
    test: @escaping @Sendable ((repeat each Input)) async throws -> Void
) async -> FuzzResult<repeat each Input> {
    @Dependency(\.corpusPersistence) var corpusPersistence

    guard corpusPersistence.exists(corpusDir),
        let snapshot: CorpusSnapshot<repeat each Input> = loadSnapshot(from: corpusDir, verbose: verbose)
    else {
        if verbose {
            print("[Fuzz] Replay - no corpus to regress")
        }
        return .empty
    }

    let config = FuzzEngineConfig(
        maxDuration: duration,
        verbose: verbose,
        projectPath: projectPath,
        coverageStrategy: .alwaysInteresting,
        edgeHook: nil,
        fileID: sourceFileID,
        filePath: sourceFilePath,
        line: line,
        column: 1
    )

    return await replayRegression(
        snapshot: snapshot,
        mutators: mutators,
        verbose: verbose,
        config: config,
        plugins: plugins,
        test: test
    )
}

// MARK: - Regression replay

/// Replay a saved corpus by seeding the engine with it and stopping when the queue drains.
///
/// The corpus inputs are the engine's only seeds (no mutator seed values are mixed in), so
/// exactly the saved inputs run. The plugins are analysis-only (`AnalysisPlugin`), so they
/// cannot emit write actions and cannot refill the queue — they run on *both* the sync and
/// async paths (one shared processor, so a stateful plugin sees iterations and `.end`), with
/// an appended `stopWhenQueueEmpty()` that terminates the run the instant the seeds drain.
/// The returned corpus is the loaded snapshot (unchanged, not re-saved); coverage is measured
/// via the `.alwaysInteresting` strategy so `.end` sees the union over every replayed input.
private func replayRegression<each Input: Codable & Sendable>(
    snapshot: CorpusSnapshot<repeat each Input>,
    mutators: (repeat Mutator<each Input>),
    verbose: Bool,
    config: FuzzEngineConfig,
    scheduleBytesExtractor: @escaping @Sendable ((repeat each Input)) -> [UInt8]? = { _ in nil },
    plugins: @escaping @Sendable () -> [AnalysisPlugin<repeat each Input>],
    test: @escaping @Sendable ((repeat each Input)) async throws -> Void
) async -> FuzzResult<repeat each Input> {
    // Replay exactly the saved corpus through one engine — no mutator seed values mixed in,
    // no parallel fan-out. Analysis plugins can't write, so running them on the sync path is
    // safe; stopWhenQueueEmpty (appended) halts the run once the seeded inputs are exhausted.
    let raw = await runEngines(
        mutators: mutators,
        seeds: snapshot.entries.map(\.input),
        perEngineSeeds: [],
        parallelism: 1,
        verbose: verbose,
        config: config,
        scheduleBytesExtractor: scheduleBytesExtractor,
        makeProcessor: {
            let lifted = (plugins() + [AnalysisPlugin<repeat each Input>.stopWhenQueueEmpty()])
                .map { $0.asFuzzPlugin() }
            return PluginProcessor<repeat each Input>(plugins: lifted)
        },
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

// MARK: - Fuzzing (single + parallel)

/// Run fuzzing (single-engine or N parallel engines). When `persist` is true, save the
/// resulting corpus; when false (the `.ephemeral` policy), nothing touches disk.
private func fuzzCampaign<each Input: Codable & Sendable>(
    mutators: (repeat Mutator<each Input>),
    seeds: [(repeat each Input)],
    corpusDir: URL,
    parallelism: Int,
    verbose: Bool,
    persist: Bool,
    config: FuzzEngineConfig,
    scheduleBytesExtractor: @escaping @Sendable ((repeat each Input)) -> [UInt8]? = { _ in nil },
    makeHandlers: @escaping @Sendable () -> [FuzzPlugin<repeat each Input>],
    test: @escaping @Sendable ((repeat each Input)) async throws -> Void
) async -> FuzzResult<repeat each Input> {
    @Dependency(\.corpusPersistence) var corpusPersistence

    // The engine no longer injects seeds itself: the mutators' seed values are part of
    // the fuzz seed list, assembled here alongside the caller's seeds.
    let baseSeeds = mutatorSeeds(mutators)

    // A single engine is just the N-engine path with N == 1: the seed split collapses to
    // one bucket and the merge short-circuits, so there's no separate single-engine branch.
    // Fuzzing shares one processor across sync and async events so stateful handlers see the
    // whole run.
    let result = await runEngines(
        mutators: mutators,
        seeds: seeds,
        perEngineSeeds: baseSeeds,
        parallelism: max(1, parallelism),
        verbose: verbose,
        config: config,
        scheduleBytesExtractor: scheduleBytesExtractor,
        makeProcessor: {
            PluginProcessor<repeat each Input>(plugins: makeHandlers())
        },
        test: test
    )

    // Persist only a non-empty corpus, so a refuzz that finds nothing leaves no stale file.
    // The `.ephemeral` policy skips persistence entirely (persist == false).
    if persist, !result.corpus.entries.isEmpty {
        do {
            try corpusPersistence.save(result.corpus, to: corpusDir, scheduleFuzzing: config.scheduleFuzzing)
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

/// Run `parallelism` independent engines, then merge. The round-robin-split `seeds` are
/// distributed one share per engine; `perEngineSeeds` (the mutators' seed values) are given to
/// every engine so each explores from the same starting points. With `parallelism == 1` the
/// split collapses to a single bucket and `mergeResults` returns that engine's result unchanged,
/// so this is also the single- and regression-replay engine path. `parallelism` must be >= 1.
///
/// `makeProcessor` builds a fresh plugin processor per engine (called inside each engine's
/// task). It must be a factory, not a value: plugins are stateful and not thread-safe, so
/// every parallel engine needs its own instances — they must never be shared across engines.
/// The one processor handles both the sync (`.iteration`) and async (`.start`/`.end`/
/// `.failureFound`) paths, so a stateful plugin observes the whole run. This is the only place
/// the coordinator builds a `FuzzEngine`; engines never persist, so the merged corpus is saved
/// by the caller.
private func runEngines<each Input: Codable & Sendable>(
    mutators: (repeat Mutator<each Input>),
    seeds: [(repeat each Input)],
    perEngineSeeds: [(repeat each Input)],
    parallelism: Int,
    verbose: Bool,
    config: FuzzEngineConfig,
    scheduleBytesExtractor: @escaping @Sendable ((repeat each Input)) -> [UInt8]? = { _ in nil },
    makeProcessor: @escaping @Sendable () -> PluginProcessor<repeat each Input>,
    test: @escaping @Sendable ((repeat each Input)) async throws -> Void
) async -> FuzzResult<repeat each Input> {
    if verbose {
        print("[Fuzz] Running \(parallelism) fuzz engine\(parallelism == 1 ? "" : "s")")
    }

    var distributedSeeds: [[(repeat each Input)]] = Array(repeating: [], count: parallelism)
    for (index, seed) in seeds.enumerated() {
        distributedSeeds[index % parallelism].append(seed)
    }

    let results = await withTaskGroup(of: FuzzResult<repeat each Input>.self) { group in
        for engineIndex in 0..<parallelism {
            let engineSeeds = perEngineSeeds + distributedSeeds[engineIndex]
            group.addTask {
                let processor = makeProcessor()
                let engine = FuzzEngine<repeat each Input>(
                    mutators: repeat each mutators,
                    config: config,
                    scheduleBytesExtractor: scheduleBytesExtractor
                )
                return await engine.run(
                    seeds: engineSeeds,
                    processSyncPlugins: { processor.processSync(event: $0, execute: $1) },
                    processAsyncPlugins: { await processor.processAsync(event: $0, execute: $1) },
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
