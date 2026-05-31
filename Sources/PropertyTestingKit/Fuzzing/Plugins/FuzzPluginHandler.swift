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

//  Closure-based plugin handler that eliminates protocol witness overhead.
//

import Testing
import Foundation
import Dependencies

/// A plugin handler with closures specialized for specific input types.
///
/// This replaces `FuzzPlugin` protocol for the hot path. Instead of generic
/// protocol methods that require runtime dispatch, this struct holds closures
/// that are already specialized for the input types.
///
/// ## Ownership
///
/// Each fuzz engine creates its own handler instances via the `makeHandlers`
/// factory. Handlers are never shared across engines, so `handleSync` does not
/// need to be `@Sendable` — it always runs synchronously on the owning engine's
/// task. Mutable state can be captured directly as `var` in the closure without
/// a wrapper.
public struct FuzzPluginHandler<each Input: Sendable>: @unchecked Sendable {
    public let id: String

    /// Synchronous event handler - hot path, called millions of times.
    /// Always invoked synchronously on the engine task that owns this handler.
    public let handleSync: (SyncPluginEvent<repeat each Input>) -> [FuzzPluginAction<repeat each Input>]

    /// Asynchronous event handler - cold path, called rarely.
    public let handleAsync: @Sendable (AsyncPluginEvent<repeat each Input>) async throws -> [FuzzPluginAction<repeat each Input>]

    @inlinable
    public init(
        id: String,
        handleSync: @escaping (SyncPluginEvent<repeat each Input>) -> [FuzzPluginAction<repeat each Input>],
        handleAsync: @escaping @Sendable (AsyncPluginEvent<repeat each Input>) async throws -> [FuzzPluginAction<repeat each Input>] = { _ in [] }
    ) {
        self.id = id
        self.handleSync = handleSync
        self.handleAsync = handleAsync
    }
}

// MARK: - Built-in Handlers

extension FuzzPluginHandler {
    /// Creates the mutation handler - selects inputs for mutation when they discover new coverage.
    ///
    /// This is the default handler that implements the core fuzzing feedback loop.
    @inlinable
    public static func mutation() -> FuzzPluginHandler<repeat each Input> {
        FuzzPluginHandler(
            id: "mutation",
            handleSync: { event in
                switch event {
                case let .iteration(context):
                    if context.discoveredNewCoverage {
                        return [.selectForMutation(.init(input: context.input))]
                    }
                    return []
                case .queueEmpty:
                    return []
                }
            }
        )
    }

    /// Creates a handler that stops the run the moment the mutation queue drains.
    ///
    /// Reacts to the `.queueEmpty` event, which fires before the engine falls
    /// back to random generation — so the run halts without executing any
    /// freshly-generated input. This is the building block for regression replay:
    /// load the corpus into the seed list, run with no generators contributing new
    /// work, and the engine replays exactly the seeded inputs (plus anything they
    /// queue) and then stops.
    ///
    /// - Parameter reason: The stop reason recorded in the run's stats. Defaults
    ///   to `.regression`.
    public static func stopWhenQueueEmpty(
        reason: FuzzStats.StopReason = .regression
    ) -> FuzzPluginHandler<repeat each Input> {
        FuzzPluginHandler(
            id: "stop_when_queue_empty",
            handleSync: { event in
                switch event {
                case .iteration:
                    return []
                case .queueEmpty:
                    return [.stop(.init(reason: reason))]
                }
            }
        )
    }

    /// Creates a corpus-cycling mutation handler.
    ///
    /// Extends the basic mutation handler with AFL-style corpus cycling:
    /// when the pending mutation queue is exhausted (the state machine fell back
    /// to fresh generation), this handler picks a random previously-interesting
    /// input and re-queues its mutations. This keeps the fuzzer exploring the
    /// neighborhood of known-good inputs rather than relying on pure random
    /// generation to re-discover interesting territory.
    ///
    /// The handler maintains its own list of interesting inputs independently of
    /// the corpus, so it works correctly in parallel fuzz mode where each engine
    /// has its own plugin instance.
    public static func corpusMutation() -> FuzzPluginHandler<repeat each Input> {
        var interestingInputs: [(repeat each Input)] = []
        @Dependency(\.fastRNG) var fastRNG: FastRNG
        let seedRNG: FastRNG = fastRNG

        return FuzzPluginHandler(
            id: "corpus_mutation",
            handleSync: { event in
                switch event {
                case let .iteration(context):
                    if context.discoveredNewCoverage {
                        interestingInputs.append(context.input)
                        return [.selectForMutation(.init(input: context.input))]
                    }

                    // When the mutation queue was exhausted (state machine fell back to
                    // fresh generation) and we have previously-interesting inputs, pick
                    // one at random and schedule its mutations.
                    if !context.fromMutationQueue, !interestingInputs.isEmpty {
                        var rng = seedRNG
                        let idx = Int.random(in: 0..<interestingInputs.count, using: &rng)
                        return [.selectForMutation(.init(input: interestingInputs[idx]))]
                    }

                    return []
                case .queueEmpty:
                    return []
                }
            }
        )
    }

    /// Creates a shrinking handler that minimizes failing inputs using delta debugging.
    ///
    /// When a test failure is found, this handler attempts to find a smaller
    /// input that still reproduces the failure, making debugging easier.
    ///
    /// - Parameters:
    ///   - config: Shrinking configuration.
    ///   - verbose: Whether to print verbose progress during shrinking.
    /// - Returns: A configured shrinking handler.
    public static func shrinking(
        config: ShrinkConfig = ShrinkConfig(),
        verbose: Bool = false
    ) -> FuzzPluginHandler<repeat each Input> where repeat each Input: Sendable {
        FuzzPluginHandler(
            id: "shrinking",
            handleSync: { _ in [] },
            handleAsync: { event in
                switch event {
                case let .failureFound(context):
                    let shrinker = MultiComponentShrinker(config: config)
                    let (minimized, stats) = await shrinker.shrink(input: context.input, test: context.test)

                    // Format minimized input for display
                    let minimizedDescription = formatMinimizedInput(minimized)

                    // Build shrink result message
                    var message = "[Shrink] Minimized failing input"
                    message += "\n  Original size: \(stats.originalSize) elements"
                    message += "\n  Minimized size: \(stats.minimizedSize) elements"
                    message += "\n  Candidates tested: \(stats.candidatesTested)"

                    if stats.minimizedSize < stats.originalSize {
                        let reduction = Double(stats.originalSize - stats.minimizedSize) / Double(stats.originalSize) * 100
                        message += "\n  Reduction: \(String(format: "%.1f", reduction))%"
                    }

                    message += "\n  Minimized input: \(minimizedDescription)"

                    if verbose {
                        print(message)
                    }

                    // Return actions: select for mutation, add to corpus, and record issue
                    return [
                        .selectForMutation(.init(input: minimized)),
                        .submitToCorpus(.init(
                            input: minimized,
                            sparseCoverage: context.sparseCoverage,
                            entryType: .failure
                        )),
                        .recordIssue(.init(
                            comment: Comment(rawValue: message),
                            sourceLocation: context.sourceLocation
                        ))
                    ]
                case .start, .end:
                    return []
                }
            }
        )
    }

    /// Creates a simple plateau detector that stops when no new coverage is found.
    ///
    /// - Parameter config: Configuration for plateau detection.
    /// - Returns: A configured plateau detector handler.
    public static func plateauDetector(
        config: SimpleCoveragePlateauDetector.Config = .init()
    ) -> FuzzPluginHandler<repeat each Input> {
        var detector = SimpleCoveragePlateauDetector(config: config)

        return FuzzPluginHandler(
            id: "plateau_detector",
            handleSync: { event in
                switch event {
                case let .iteration(context):
                    detector.record(discoveredNewCoverage: context.discoveredNewCoverage)

                    if detector.hasPlateaued {
                        return [.stop(FuzzPluginAction<repeat each Input>.StopAction(reason: .custom("coverage_plateaued")))]
                    }

                    return []
                case .queueEmpty:
                    return []
                }
            }
        )
    }

    /// Creates a STADS plateau detector using Good-Turing estimator.
    ///
    /// Uses statistical principles from species discovery to estimate the
    /// probability of finding new coverage. More principled than simple
    /// window-based approaches.
    ///
    /// - Parameters:
    ///   - minDiscoveryProbability: Minimum probability before declaring plateau. Default is 0.001.
    ///   - confirmationChecks: Consecutive low-probability checks required. Default is 3.
    ///   - checkInterval: Iterations between probability recalculations. Default is 100.
    /// - Returns: A configured STADS plateau detector handler.
    public static func stadsDetector(
        minDiscoveryProbability: Double = 0.001,
        confirmationChecks: Int = 3,
        checkInterval: Int = 100
    ) -> FuzzPluginHandler<repeat each Input> {
        stadsDetector(config: .init(
            minDiscoveryProbability: minDiscoveryProbability,
            confirmationChecks: confirmationChecks,
            checkInterval: checkInterval
        ))
    }

    /// Creates a STADS plateau detector with custom configuration.
    ///
    /// - Parameter config: The STADS detector configuration.
    /// - Returns: A configured STADS plateau detector handler.
    public static func stadsDetector(
        config: STADSPlateauDetector.Config
    ) -> FuzzPluginHandler<repeat each Input> {
        var detector = STADSPlateauDetector(config: config)

        return FuzzPluginHandler(
            id: "stads_detector",
            handleSync: { event in
                switch event {
                case let .iteration(context):
                    detector.record(discoveredNewCoverage: context.discoveredNewCoverage)

                    if detector.hasPlateaued {
                        return [.stop(FuzzPluginAction<repeat each Input>.StopAction(reason: .custom("stads_plateau")))]
                    }

                    return []
                case .queueEmpty:
                    return []
                }
            }
        )
    }

    /// Creates a saturation plateau detector using saturation-based metrics.
    ///
    /// Models coverage growth as an asymptotic process and stops when saturation
    /// approaches the estimated maximum coverage.
    ///
    /// - Parameters:
    ///   - minSaturation: Saturation level (0-1) to declare plateau. Default is 0.99.
    ///   - minGrowthRate: Minimum growth rate before plateau. Default is 0.0001.
    ///   - windowSize: Window size for growth rate calculation. Default is 500.
    ///   - confirmationWindows: Consecutive low-growth windows required. Default is 3.
    /// - Returns: A configured saturation plateau detector handler.
    public static func saturationDetector(
        minSaturation: Double = 0.99,
        minGrowthRate: Double = 0.0001,
        windowSize: Int = 500,
        confirmationWindows: Int = 3
    ) -> FuzzPluginHandler<repeat each Input> {
        saturationDetector(config: .init(
            minSaturation: minSaturation,
            minGrowthRate: minGrowthRate,
            windowSize: windowSize,
            confirmationWindows: confirmationWindows
        ))
    }

    /// Creates a saturation plateau detector with custom configuration.
    ///
    /// - Parameter config: The saturation detector configuration.
    /// - Returns: A configured saturation plateau detector handler.
    public static func saturationDetector(
        config: SaturationPlateauDetector.Config
    ) -> FuzzPluginHandler<repeat each Input> {
        var detector = SaturationPlateauDetector(config: config)

        return FuzzPluginHandler(
            id: "saturation_detector",
            handleSync: { event in
                switch event {
                case let .iteration(context):
                    detector.record(discoveredNewCoverage: context.discoveredNewCoverage)

                    if detector.hasPlateaued {
                        return [.stop(FuzzPluginAction<repeat each Input>.StopAction(reason: .custom("saturation_plateau")))]
                    }

                    return []
                case .queueEmpty:
                    return []
                }
            }
        )
    }

    /// Creates an energy-based mutation handler using the Entropic algorithm.
    ///
    /// Ports libFuzzer's Entropic energy scheduler. Each interesting input is
    /// assigned an energy score based on how many globally-rare coverage edges it
    /// covers. When the mutation queue drains, the next input to mutate is chosen
    /// by weighted-random selection proportional to `2^energy`, so inputs covering
    /// rare edges are selected more often.
    ///
    /// Energy formula (Shannon entropy of rare-feature incidence distribution):
    /// - For each rare feature covered by the entry, subtract `(globalFreq+1)*log(globalFreq+1)`
    ///   from the energy and add `(globalFreq+1)` to the sum of incidences.
    /// - Add an abundance term: `-(mutations+1)*log(mutations+1)` to penalise
    ///   over-mutated inputs.
    /// - Normalize: `energy = energy/sumIncidence + log(sumIncidence)`.
    /// - Over-fuzzing guard: if an entry has been mutated more than
    ///   `kMaxMutationFactor × average`, its weight is set to zero.
    ///
    /// A feature is considered "rare" when fewer than `rareFeatureThreshold`
    /// corpus entries cover it (default: 3).
    public static func energyMutation(
        rareFeatureThreshold: Int = 3,
        maxMutationFactor: Int = 20
    ) -> FuzzPluginHandler<repeat each Input> {
        var entryInputs: [(repeat each Input)] = []
        var entryFeatures: [[UInt32]] = []
        var entryMutations: [Int] = []
        var globalFeatureFreqs: [UInt32: Int] = [:]
        var totalMutations = 0

        @Dependency(\.fastRNG) var fastRNG: FastRNG
        let seedRNG: FastRNG = fastRNG

        return FuzzPluginHandler(
            id: "energy_mutation",
            handleSync: { event in
                switch event {
                case let .iteration(context):
                    if context.discoveredNewCoverage, let coverage = context.sparseCoverage {
                        // Register new entry with its features.
                        for feature in coverage.indices {
                            globalFeatureFreqs[feature, default: 0] += 1
                        }
                        entryInputs.append(context.input)
                        entryFeatures.append(coverage.indices)
                        entryMutations.append(0)

                        // Immediately schedule mutations for the newly-interesting input.
                        return [.selectForMutation(.init(input: context.input))]
                    }

                    // When the mutation queue has drained, pick the next entry to
                    // mutate using energy-weighted selection.
                    if !context.fromMutationQueue, !entryInputs.isEmpty {
                        var rng = seedRNG
                        let count = entryInputs.count
                        let totalRareFeatures = globalFeatureFreqs.values
                            .filter { $0 <= rareFeatureThreshold }.count

                        let weights = (0..<count).map { i in
                            entropicWeight(
                                features: entryFeatures[i],
                                mutations: entryMutations[i],
                                globalFreqs: globalFeatureFreqs,
                                totalRareFeatures: totalRareFeatures,
                                totalMutations: totalMutations,
                                corpusSize: count,
                                rareFeatureThreshold: rareFeatureThreshold,
                                maxMutationFactor: maxMutationFactor
                            )
                        }

                        let selectedIdx = weightedRandomIndex(weights: weights, using: &rng)
                        entryMutations[selectedIdx] += 1
                        totalMutations += 1

                        return [.selectForMutation(.init(input: entryInputs[selectedIdx]))]
                    }

                    return []
                case .queueEmpty:
                    return []
                }
            }
        )
    }

    /// Creates a coverage gap analysis handler.
    ///
    /// Analyzes coverage at the end of fuzzing and reports gaps in coverage
    /// as issues at the specific source locations.
    ///
    /// - Parameter config: Configuration for gap detection.
    /// - Returns: A configured coverage gap handler.
    public static func coverageGap(
        config: CoverageGapDetector.Config = .init()
    ) -> FuzzPluginHandler<repeat each Input> {
        let detector = CoverageGapDetector(config: config)

        return FuzzPluginHandler(
            id: "coverage_gap",
            handleSync: { _ in [] },
            handleAsync: { event in
                switch event {
                case .start:
                    // Get counters ready, resolve source locations up front.
                    await SanCovCounters.startPreWarmingSourceLocations()
                    return []
                case let .end(endContext):
                    let coverageGapReport = await detector
                        .detect(
                            from: endContext.totalCoveredIndices,
                            projectPath: endContext.projectPath
                        )

                    return constructCoverageGapActions(report: coverageGapReport, endContext: endContext)
                case .failureFound:
                    return []
                }
            }
        )
    }
}

// MARK: - Helper Functions

/// Format minimized input for display.
private func formatMinimizedInput<each T>(_ input: (repeat each T)) -> String {
    // Use Mirror to get a readable representation
    let mirror = Mirror(reflecting: input)
    if mirror.children.isEmpty {
        return String(describing: input)
    }

    // For tuples, format each element
    var elements: [String] = []
    for child in mirror.children {
        elements.append(String(describing: child.value))
    }
    return "(\(elements.joined(separator: ", ")))"
}

/// Construct issue actions for coverage gap report.
private func constructCoverageGapActions<each T: Sendable>(
    report: CoverageGapReport,
    endContext: AsyncPluginEvent<repeat each T>.EndContext
) -> [FuzzPluginAction<repeat each T>] {
    guard !report.gaps.isEmpty else { return [] }

    var actions: [FuzzPluginAction<repeat each T>] = []

    for gap in report.gaps {
        let file = URL(fileURLWithPath: gap.filename).lastPathComponent
        let pct = String(format: "%.0f", gap.coveragePercentage)

        // Create an issue for each uncovered region at its actual source location
        for region in gap.uncoveredRegions where region.lineStart > 0 {
            let desc = region.isBranch ? "branch not taken" : "code not executed"
            let message = "Coverage gap: \(gap.functionName) (\(pct)% covered) - \(desc)"

            // Use the region's DWARF-resolved file path if available, else fall back to gap's filename
            let effectiveFilePath = region.filePath ?? gap.filename
            let fileID = fileIDFromPath(effectiveFilePath)
            let sourceLocation = SourceLocation(
                fileID: fileID,
                filePath: effectiveFilePath,
                line: region.lineStart,
                column: max(1, region.columnStart)
            )

            actions.append(.recordIssue(FuzzPluginAction<repeat each T>.IssueAction(
                comment: Comment(rawValue: message),
                sourceLocation: sourceLocation
            )))
        }

        // If no regions have line info, fall back to fuzz call location
        if gap.uncoveredRegions.allSatisfy({ $0.lineStart == 0 }) {
            let message = "Coverage gap: \(gap.functionName) in \(file) is \(pct)% covered"
            actions.append(.recordIssue(FuzzPluginAction<repeat each T>.IssueAction(
                comment: Comment(rawValue: message),
                sourceLocation: endContext.sourceLocation
            )))
        }
    }

    return actions
}

/// Construct a fileID from a file path.
/// Format: "ModuleName/FileName.swift"
private func fileIDFromPath(_ path: String) -> String {
    let url = URL(fileURLWithPath: path)
    let fileName = url.lastPathComponent

    // Try to extract module name from path (e.g., "Sources/ModuleName/...")
    let pathComponents = url.pathComponents
    if let sourcesIndex = pathComponents.lastIndex(of: "Sources"),
       sourcesIndex + 1 < pathComponents.count {
        let moduleName = pathComponents[sourcesIndex + 1]
        return "\(moduleName)/\(fileName)"
    }

    // Try "Tests/ModuleName/..."
    if let testsIndex = pathComponents.lastIndex(of: "Tests"),
       testsIndex + 1 < pathComponents.count {
        let moduleName = pathComponents[testsIndex + 1]
        return "\(moduleName)/\(fileName)"
    }

    // Fallback: use parent directory as module name
    if pathComponents.count >= 2 {
        let parentDir = pathComponents[pathComponents.count - 2]
        return "\(parentDir)/\(fileName)"
    }

    // Last resort
    return "Unknown/\(fileName)"
}

// MARK: - Entropic Energy Helpers

/// Compute the Entropic energy weight for a corpus entry.
///
/// Returns `pow(2, energy)` — always positive, so entries with higher energy
/// get proportionally more mutations. Returns 1.0 (uniform) when no rare
/// features have been recorded yet.
private func entropicWeight(
    features: [UInt32],
    mutations: Int,
    globalFreqs: [UInt32: Int],
    totalRareFeatures: Int,
    totalMutations: Int,
    corpusSize: Int,
    rareFeatureThreshold: Int,
    maxMutationFactor: Int
) -> Double {
    // Over-fuzzing guard: zero out entries mutated far beyond the average.
    if corpusSize > 0, totalMutations > 0 {
        let avgMutations = totalMutations / corpusSize
        if avgMutations > 0, mutations / maxMutationFactor > avgMutations {
            return 0.0
        }
    }

    var energy = 0.0
    var sumIncidence = 0.0
    var coveredRareFeatures = 0

    for feature in features {
        let globalFreq = globalFreqs[feature] ?? 1
        guard globalFreq <= rareFeatureThreshold else { continue }
        let localIncidence = Double(globalFreq + 1)
        energy -= localIncidence * log(localIncidence)
        sumIncidence += localIncidence
        coveredRareFeatures += 1
    }

    // Uncovered rare features add to the denominator but not to the numerator
    // (their contribution to energy is -1*log(1) = 0).
    let uncoveredRare = max(0, totalRareFeatures - coveredRareFeatures)
    sumIncidence += Double(uncoveredRare)

    // Abundance term: penalise inputs that have been mutated many times.
    let abundanceIncidence = Double(mutations + 1)
    energy -= abundanceIncidence * log(abundanceIncidence)
    sumIncidence += abundanceIncidence

    guard sumIncidence > 0 else { return 1.0 }
    return pow(2.0, energy / sumIncidence + log(sumIncidence))
}

/// Weighted-random index selection. Falls back to uniform random if all weights are zero.
private func weightedRandomIndex(weights: [Double], using rng: inout some RandomNumberGenerator) -> Int {
    let total = weights.reduce(0.0, +)
    guard total > 0 else {
        return Int.random(in: 0..<weights.count, using: &rng)
    }
    let r = Double.random(in: 0..<total, using: &rng)
    var cumsum = 0.0
    for (i, w) in weights.enumerated() {
        cumsum += w
        if r < cumsum { return i }
    }
    return weights.count - 1
}

// MARK: - Processor

/// Processes plugin handlers without protocol witness overhead.
@usableFromInline
struct PluginHandlerProcessor<each Input: Sendable>: @unchecked Sendable {
    @usableFromInline
    let handlers: [FuzzPluginHandler<repeat each Input>]

    @inlinable
    init(handlers: [FuzzPluginHandler<repeat each Input>]) {
        self.handlers = handlers
    }

    /// Process a synchronous event - hot path.
    @inlinable
    func processSync(
        event: consuming SyncPluginEvent<repeat each Input>,
        execute: (FuzzPluginAction<repeat each Input>) -> Void
    ) {
        for handler in handlers {
            let actions = handler.handleSync(copy event)
            for action in actions {
                execute(action)
            }
        }
        _ = consume event
    }

    /// Process an asynchronous event - cold path.
    @inlinable
    func processAsync(
        isolation: isolated (any Actor)? = #isolation,
        event: consuming AsyncPluginEvent<repeat each Input>,
        execute: (FuzzPluginAction<repeat each Input>) -> Void
    ) async {
        for handler in handlers {
            do {
                let actions = try await handler.handleAsync(copy event)
                for action in actions {
                    execute(action)
                }
            } catch {
                // Plugin errors are non-fatal
            }
        }
        _ = consume event
    }
}
