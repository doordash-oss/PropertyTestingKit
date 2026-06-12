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

//  Closure-based plugins that eliminate protocol witness overhead.
//

import Testing
import Foundation
import Dependencies

/// A plugin with closures specialized for specific input types.
///
/// Holds closures already specialized for the input types, rather than generic
/// protocol methods that require runtime dispatch, this struct holds closures
/// that are already specialized for the input types.
///
/// ## Ownership
///
/// Each fuzz engine creates its own plugin instances via the plugins
/// factory. Plugins are never shared across engines, so `handleSync` does not
/// need to be `@Sendable` — it always runs synchronously on the owning engine's
/// task. Mutable state can be captured directly as `var` in the closure without
/// a wrapper.
public struct FuzzPlugin<each Input: Sendable>: @unchecked Sendable {
    public let id: String

    /// Synchronous event handler - hot path, called millions of times.
    /// Always invoked synchronously on the engine task that owns this plugin.
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

/// A plugin restricted to *analysis* — it can only emit `AnalysisAction`
/// (`stop` / `recordIssue`), never a write action.
///
/// This is the plugin type `regress(...)` accepts. Because its closures return
/// `[AnalysisAction]`, and `AnalysisAction` has no write cases, a plugin used in a
/// replay cannot mutate the run or the corpus — the restriction is enforced by the
/// type, with no runtime check. Analysis plugins are also usable inside `fuzz(...)`
/// by lifting them with `asFuzzPlugin()`.
public struct AnalysisPlugin<each Input: Sendable>: @unchecked Sendable {
    public let id: String

    /// Synchronous event handler — hot path. Always invoked synchronously on the
    /// engine task that owns this plugin.
    public let handleSync: (SyncPluginEvent<repeat each Input>) -> [AnalysisAction<repeat each Input>]

    /// Asynchronous event handler — cold path, called rarely.
    public let handleAsync: @Sendable (AsyncPluginEvent<repeat each Input>) async throws -> [AnalysisAction<repeat each Input>]

    @inlinable
    public init(
        id: String,
        handleSync: @escaping (SyncPluginEvent<repeat each Input>) -> [AnalysisAction<repeat each Input>],
        handleAsync: @escaping @Sendable (AsyncPluginEvent<repeat each Input>) async throws -> [AnalysisAction<repeat each Input>] = { _ in [] }
    ) {
        self.id = id
        self.handleSync = handleSync
        self.handleAsync = handleAsync
    }
}

extension AnalysisPlugin {
    /// Lift this analysis plugin into a full `FuzzPlugin` so it can run in a
    /// `fuzz(...)` campaign alongside exploration plugins. Each emitted action is
    /// widened via `AnalysisAction.lifted()`, which only ever yields `.stop` /
    /// `.recordIssue`.
    @inlinable
    public func asFuzzPlugin() -> FuzzPlugin<repeat each Input> {
        FuzzPlugin(
            id: id,
            handleSync: { event in handleSync(event).map { $0.lifted() } },
            handleAsync: { event in try await handleAsync(event).map { $0.lifted() } }
        )
    }
}

// MARK: - Built-in Plugins

extension FuzzPlugin {
    /// Creates the mutation plugin - selects inputs for mutation when they discover new coverage.
    ///
    /// This is the default plugin that implements the core fuzzing feedback loop.
    @inlinable
    public static func mutation() -> FuzzPlugin<repeat each Input> {
        FuzzPlugin(
            id: "mutation",
            handleSync: { event in
                switch event {
                case let .iteration(context):
                    if context.newCoverage != nil {
                        return [.selectForMutation(.init(input: context.input, scheduleBytes: context.scheduleBytes))]
                    }
                    return []
                }
            }
        )
    }

    /// Creates a shrinking plugin that minimizes failing inputs using delta debugging.
    ///
    /// When a test failure is found, this plugin attempts to find a smaller
    /// input that still reproduces the failure, making debugging easier.
    ///
    /// - Parameters:
    ///   - config: Shrinking configuration.
    ///   - verbose: Whether to print verbose progress during shrinking.
    /// - Returns: A configured shrinking plugin.
    public static func shrinking(
        config: ShrinkConfig = ShrinkConfig(),
        verbose: Bool = false
    ) -> FuzzPlugin<repeat each Input> where repeat each Input: Sendable {
        FuzzPlugin(
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
                        .selectForMutation(.init(input: minimized, scheduleBytes: context.scheduleBytes)),
                        .submitToCorpus(.init(
                            input: minimized,
                            scheduleBytes: context.scheduleBytes,
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

}

// The bus-plugin schedulers (`corpusMutation`, Entropic `energyMutation`) are
// gone: mutation scheduling is the `MutationScheduler` pool's job. The pure
// Entropic scoring math below (`entropicWeightCombining` & co.) stays, pinned
// by its characterization tests, for the pool's entropic weight advisor.

// MARK: - Built-in Analysis Plugins
//
// Plugins that emit only `AnalysisAction` (stop / recordIssue). They are valid in
// both `fuzz(...)` and `regress(...)`; in `fuzz`, lift with `asFuzzPlugin()`.

extension AnalysisPlugin {
    /// Creates a plugin that stops the run the moment the mutation queue drains.
    ///
    /// Reacts to the iteration whose `queueCount` reaches zero — the last queued
    /// input. The engine checks the stop before taking another input, so the run
    /// halts without executing any freshly-generated one. This is the building
    /// block for regression replay: load the corpus into the seed list, run with
    /// no generators contributing new work, and the engine replays exactly the
    /// seeded inputs (plus anything they queue) and then stops.
    ///
    /// - Parameter reason: The stop reason recorded in the run's stats. Defaults
    ///   to `.regressionTestCompleted`.
    public static func stopWhenQueueEmpty(
        reason: FuzzStats.StopReason = .regressionTestCompleted
    ) -> AnalysisPlugin<repeat each Input> {
        AnalysisPlugin(
            id: "stop_when_queue_empty",
            handleSync: { event in
                switch event {
                case let .iteration(context):
                    return context.queueCount == 0 ? [.stop(.init(reason: reason))] : []
                }
            }
        )
    }

    /// Creates a plugin that stops the run as soon as the first failure is found.
    ///
    /// Reacts to the `failureFound` event and emits a single `.stop`. In a
    /// parallel `fuzz(...)` run this halts the engine that found the
    /// counterexample and, because the engines cancel their siblings on the first
    /// failure, brings the whole campaign down promptly — so the run returns at
    /// the first counterexample with an accurate time-to-find, instead of letting
    /// the other engines keep generating inputs. Handy when you only care
    /// *whether* (and how quickly) a property can be broken, not about collecting
    /// every distinct failure.
    ///
    /// - Parameter reason: The stop reason recorded in the run's stats. Defaults
    ///   to `.custom("first_failure")`.
    public static func stopOnFirstFailure(
        reason: FuzzStats.StopReason = .custom("first_failure")
    ) -> AnalysisPlugin<repeat each Input> {
        AnalysisPlugin(
            id: "stop_on_first_failure",
            handleSync: { _ in [] },
            handleAsync: { event in
                if case .failureFound = event {
                    // Campaign-scoped: a found counterexample is the whole run's
                    // goal, so cancel the sibling engines too, not just this one.
                    return [.stop(.init(reason: reason, scope: .campaign))]
                }
                return []
            }
        )
    }

    /// Creates a simple plateau detector that stops when no new coverage is found.
    ///
    /// - Parameter config: Configuration for plateau detection.
    /// - Returns: A configured plateau detector plugin.
    public static func plateauDetector(
        config: SimpleCoveragePlateauDetector.Config = .init()
    ) -> AnalysisPlugin<repeat each Input> {
        var detector = SimpleCoveragePlateauDetector(config: config)

        return AnalysisPlugin(
            id: "plateau_detector",
            handleSync: { event in
                switch event {
                case let .iteration(context):
                    detector.record(discoveredNewCoverage: context.newCoverage != nil)

                    if detector.hasPlateaued {
                        return [.stop(FuzzPluginAction<repeat each Input>.StopAction(reason: .custom("coverage_plateaued")))]
                    }

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
    /// - Returns: A configured STADS plateau detector plugin.
    public static func stadsDetector(
        minDiscoveryProbability: Double = 0.001,
        confirmationChecks: Int = 3,
        checkInterval: Int = 100
    ) -> AnalysisPlugin<repeat each Input> {
        stadsDetector(config: .init(
            minDiscoveryProbability: minDiscoveryProbability,
            confirmationChecks: confirmationChecks,
            checkInterval: checkInterval
        ))
    }

    /// Creates a STADS plateau detector with custom configuration.
    ///
    /// - Parameter config: The STADS detector configuration.
    /// - Returns: A configured STADS plateau detector plugin.
    public static func stadsDetector(
        config: STADSPlateauDetector.Config
    ) -> AnalysisPlugin<repeat each Input> {
        var detector = STADSPlateauDetector(config: config)

        return AnalysisPlugin(
            id: "stads_detector",
            handleSync: { event in
                switch event {
                case let .iteration(context):
                    detector.record(discoveredNewCoverage: context.newCoverage != nil)

                    if detector.hasPlateaued {
                        return [.stop(FuzzPluginAction<repeat each Input>.StopAction(reason: .custom("stads_plateau")))]
                    }

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
    /// - Returns: A configured saturation plateau detector plugin.
    public static func saturationDetector(
        minSaturation: Double = 0.99,
        minGrowthRate: Double = 0.0001,
        windowSize: Int = 500,
        confirmationWindows: Int = 3
    ) -> AnalysisPlugin<repeat each Input> {
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
    /// - Returns: A configured saturation plateau detector plugin.
    public static func saturationDetector(
        config: SaturationPlateauDetector.Config
    ) -> AnalysisPlugin<repeat each Input> {
        var detector = SaturationPlateauDetector(config: config)

        return AnalysisPlugin(
            id: "saturation_detector",
            handleSync: { event in
                switch event {
                case let .iteration(context):
                    detector.record(discoveredNewCoverage: context.newCoverage != nil)

                    if detector.hasPlateaued {
                        return [.stop(FuzzPluginAction<repeat each Input>.StopAction(reason: .custom("saturation_plateau")))]
                    }

                    return []
                }
            }
        )
    }

    /// Creates a coverage gap analysis plugin.
    ///
    /// Analyzes coverage at the end of fuzzing and reports gaps in coverage
    /// as issues at the specific source locations.
    ///
    /// - Parameter config: Configuration for gap detection.
    /// - Returns: A configured coverage gap plugin.
    public static func coverageGap(
        config: CoverageGapDetector.Config = .init()
    ) -> AnalysisPlugin<repeat each Input> {
        let detector = CoverageGapDetector(config: config)

        return AnalysisPlugin(
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

// MARK: - Analysis Plugins Usable in fuzz()
//
// Every analysis plugin is also valid inside a `fuzz(...)` campaign. These mirror the
// `AnalysisPlugin` factories and lift the result with `asFuzzPlugin()`, so a fuzz call can
// just write `.coverageGap()` instead of `AnalysisPlugin.coverageGap().asFuzzPlugin()`.
// (In a `regress(...)` context the same spelling resolves to the `AnalysisPlugin` factory.)

extension FuzzPlugin {
    /// Lifted `AnalysisPlugin.stopWhenQueueEmpty(reason:)` for use in `fuzz(...)`.
    public static func stopWhenQueueEmpty(
        reason: FuzzStats.StopReason = .regressionTestCompleted
    ) -> FuzzPlugin<repeat each Input> {
        AnalysisPlugin.stopWhenQueueEmpty(reason: reason).asFuzzPlugin()
    }

    /// Lifted `AnalysisPlugin.stopOnFirstFailure(reason:)` for use in `fuzz(...)`.
    public static func stopOnFirstFailure(
        reason: FuzzStats.StopReason = .custom("first_failure")
    ) -> FuzzPlugin<repeat each Input> {
        AnalysisPlugin.stopOnFirstFailure(reason: reason).asFuzzPlugin()
    }

    /// Lifted `AnalysisPlugin.plateauDetector(config:)` for use in `fuzz(...)`.
    public static func plateauDetector(
        config: SimpleCoveragePlateauDetector.Config = .init()
    ) -> FuzzPlugin<repeat each Input> {
        AnalysisPlugin.plateauDetector(config: config).asFuzzPlugin()
    }

    /// Lifted `AnalysisPlugin.stadsDetector(...)` for use in `fuzz(...)`.
    public static func stadsDetector(
        minDiscoveryProbability: Double = 0.001,
        confirmationChecks: Int = 3,
        checkInterval: Int = 100
    ) -> FuzzPlugin<repeat each Input> {
        AnalysisPlugin.stadsDetector(
            minDiscoveryProbability: minDiscoveryProbability,
            confirmationChecks: confirmationChecks,
            checkInterval: checkInterval
        ).asFuzzPlugin()
    }

    /// Lifted `AnalysisPlugin.stadsDetector(config:)` for use in `fuzz(...)`.
    public static func stadsDetector(
        config: STADSPlateauDetector.Config
    ) -> FuzzPlugin<repeat each Input> {
        AnalysisPlugin.stadsDetector(config: config).asFuzzPlugin()
    }

    /// Lifted `AnalysisPlugin.saturationDetector(...)` for use in `fuzz(...)`.
    public static func saturationDetector(
        minSaturation: Double = 0.99,
        minGrowthRate: Double = 0.0001,
        windowSize: Int = 500,
        confirmationWindows: Int = 3
    ) -> FuzzPlugin<repeat each Input> {
        AnalysisPlugin.saturationDetector(
            minSaturation: minSaturation,
            minGrowthRate: minGrowthRate,
            windowSize: windowSize,
            confirmationWindows: confirmationWindows
        ).asFuzzPlugin()
    }

    /// Lifted `AnalysisPlugin.saturationDetector(config:)` for use in `fuzz(...)`.
    public static func saturationDetector(
        config: SaturationPlateauDetector.Config
    ) -> FuzzPlugin<repeat each Input> {
        AnalysisPlugin.saturationDetector(config: config).asFuzzPlugin()
    }

    /// Lifted `AnalysisPlugin.coverageGap(config:)` for use in `fuzz(...)`.
    public static func coverageGap(
        config: CoverageGapDetector.Config = .init()
    ) -> FuzzPlugin<repeat each Input> {
        AnalysisPlugin.coverageGap(config: config).asFuzzPlugin()
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
) -> [AnalysisAction<repeat each T>] {
    guard !report.gaps.isEmpty else { return [] }

    var actions: [AnalysisAction<repeat each T>] = []

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

/// Per-entry rarity terms of the entropic energy: everything that depends on
/// the entry's features and the GLOBAL feature frequencies — which change
/// only when a new entry joins the corpus. Caching these moves the
/// O(features) work to acceptance time; the drain-time hot path combines
/// them with the abundance term in O(1) per entry.
struct EntropicRarityTerms {
    /// `-Σ (freq+1)·ln(freq+1)` over the entry's rare features.
    let energy: Double
    /// `Σ (freq+1)` over the entry's rare features.
    let sumIncidence: Double
    /// How many rare features the entry covers.
    let coveredRare: Int
}

/// Compute an entry's rarity terms from its OBSERVATION YIELD — how many
/// times each rare feature has been seen across this seed's accepted mutants
/// (its own discovery counts as the first observation). This is Entropic's
/// information-gain form: repeated rare observations contribute
/// `-count·ln(count)` entropy and `count` incidence, so seeds whose mutants
/// keep eliciting rare features hold energy, while the abundance term decays
/// seeds that execute without yielding.
func entropicYieldRarityTerms(
    yield: [UInt64: Int],
    globalFreqs: [UInt64: Int],
    rareFeatureThreshold: Int
) -> EntropicRarityTerms {
    var energy = 0.0
    var sumIncidence = 0.0
    var coveredRare = 0
    for (feature, count) in yield {
        let globalFreq = globalFreqs[feature] ?? 1
        guard globalFreq <= rareFeatureThreshold else { continue }
        let localIncidence = Double(count)
        energy -= localIncidence * log(localIncidence)
        sumIncidence += localIncidence
        coveredRare += 1
    }
    return EntropicRarityTerms(energy: energy, sumIncidence: sumIncidence, coveredRare: coveredRare)
}

/// Compute an entry's rarity terms from the current global frequencies.
/// Called at acceptance time (frequencies only change then), not per drain.
func entropicRarityTerms(
    features: [UInt64],
    globalFreqs: [UInt64: Int],
    rareFeatureThreshold: Int
) -> EntropicRarityTerms {
    var energy = 0.0
    var sumIncidence = 0.0
    var coveredRare = 0
    for feature in features {
        let globalFreq = globalFreqs[feature] ?? 1
        guard globalFreq <= rareFeatureThreshold else { continue }
        let localIncidence = Double(globalFreq + 1)
        energy -= localIncidence * log(localIncidence)
        sumIncidence += localIncidence
        coveredRare += 1
    }
    return EntropicRarityTerms(energy: energy, sumIncidence: sumIncidence, coveredRare: coveredRare)
}

/// Combine cached rarity terms with the per-drain abundance term. O(1).
/// Must agree exactly with `entropicWeight` (see the equivalence test).
func entropicWeightCombining(
    cache: EntropicRarityTerms,
    mutations: Int,
    totalRareFeatures: Int,
    totalMutations: Int,
    corpusSize: Int,
    maxMutationFactor: Int
) -> Double {
    if corpusSize > 0, totalMutations > 0 {
        let avgMutations = totalMutations / corpusSize
        if avgMutations > 0, mutations / maxMutationFactor > avgMutations {
            return 0.0
        }
    }

    var energy = cache.energy
    var sumIncidence = cache.sumIncidence

    let uncoveredRare = max(0, totalRareFeatures - cache.coveredRare)
    sumIncidence += Double(uncoveredRare)

    let abundanceIncidence = Double(mutations + 1)
    energy -= abundanceIncidence * log(abundanceIncidence)
    sumIncidence += abundanceIncidence

    guard sumIncidence > 0 else { return 1.0 }
    return pow(2.0, energy / sumIncidence + log(sumIncidence))
}

/// Compute the Entropic energy weight for a corpus entry.
///
/// Returns `pow(2, energy)` — always positive, so entries with higher energy
/// get proportionally more mutations. Returns 1.0 (uniform) when no rare
/// features have been recorded yet.
///
/// Reference (fused) form of `entropicRarityTerms` + `entropicWeightCombining`;
/// the plugin's hot path uses the split form, and the equivalence test holds
/// the two together.
func entropicWeight(
    features: [UInt64],
    mutations: Int,
    globalFreqs: [UInt64: Int],
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
func weightedRandomIndex(weights: [Double], using rng: inout some RandomNumberGenerator) -> Int {
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

/// Processes plugins without protocol witness overhead.
@usableFromInline
struct PluginProcessor<each Input: Sendable>: @unchecked Sendable {
    @usableFromInline
    let plugins: [FuzzPlugin<repeat each Input>]

    @inlinable
    init(plugins: [FuzzPlugin<repeat each Input>]) {
        self.plugins = plugins
    }

    /// Process a synchronous event - hot path.
    @inlinable
    func processSync(
        event: consuming SyncPluginEvent<repeat each Input>,
        execute: (FuzzPluginAction<repeat each Input>) -> Void
    ) {
        for plugin in plugins {
            let actions = plugin.handleSync(copy event)
            for action in actions {
                execute(action)
            }
        }
        _ = consume event
    }

    /// Process an asynchronous event - cold path.
    @inlinable
    func processAsync(
        event: consuming AsyncPluginEvent<repeat each Input>,
        execute: (FuzzPluginAction<repeat each Input>) -> Void
    ) async {
        for plugin in plugins {
            do {
                let actions = try await plugin.handleAsync(copy event)
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
