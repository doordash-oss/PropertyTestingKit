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

//  Coverage-guided fuzzing engine that combines mutation and generation.
//

import Dependencies
import Foundation
import ScheduleControl
import Testing

// MARK: - FuzzEngine

/// A coverage-guided fuzzing engine.
///
/// Given seeds, mutators, plugin processors, and a test, it runs the fuzzing loop and
/// returns a `FuzzResult` with the in-memory corpus it built.
///
/// ## Algorithm
///
/// Fuzzing follows AFL/FuzzChick's approach:
/// 1. Start with the provided seeds
/// 2. Run each input, capture coverage signature
/// 3. If signature is new, add to corpus
/// 4. Select corpus entries for mutation (energy-based)
/// 5. Mutate inputs, repeat
/// 6. Stop when: queue drained (plugin), time limit, or coverage plateau
///
final class FuzzEngine<each Input: Codable & Sendable>: @unchecked Sendable {
    @Dependency(\.dateClient) private var dateClient
    @Dependency(\.corpusRegistry) private var corpusRegistry

    // Type alias for the combined input tuple
    typealias InputTuple = (repeat each Input)

    /// Synchronous plugin processor for iteration events (hot path).
    typealias SyncPluginProcessorFn = @Sendable (
        consuming SyncPluginEvent<repeat each Input>,
        (FuzzPluginAction<repeat each Input>) -> Void
    ) -> Void

    /// Asynchronous plugin processor for rare events (cold path).
    typealias AsyncPluginProcessorFn = @Sendable (
        consuming AsyncPluginEvent<repeat each Input>,
        (FuzzPluginAction<repeat each Input>) -> Void
    ) async -> Void

    // MARK: - Properties
    private let config: FuzzEngineConfig
    private let mutators: (repeat Mutator<each Input>)
    private let inputSize: Int

    /// Extracts schedule bytes from an input (element 0 of the flattened pack
    /// when schedule fuzzing; `nil` otherwise). Threaded to the state machine and
    /// regression replay so they wrap execution in `ScheduleController.run`.
    private let scheduleBytesExtractor: @Sendable ((repeat each Input)) -> [UInt8]?

    /// The coverage strategy. Its evaluator is built fresh in `run()` so each parallel
    /// engine gets its own per-engine state (e.g. a distinct trie/index).
    private let coverageStrategy: CoverageStrategy<repeat each Input>

    /// Initialize with mutators.
    ///
    /// - Parameters:
    ///   - mutators: The mutators, one for each input type, passed as variadic
    ///     pack arguments.
    ///   - config: Fuzzing configuration.
    ///   - scheduleBytesExtractor: Extracts schedule bytes from an input. Supply
    ///     `{ $0.0 }` when running over the flattened pack `([UInt8], repeat each
    ///     UserInput)`.
    ///
    /// - Note: `mutators` is a *variadic pack* parameter, not a tuple, on purpose.
    ///   Building the flattened mutator pack by materializing a mixed tuple
    ///   `(scheduleByteMutator, repeat each userMutators)` and then iterating it as
    ///   a pack mis-indexes at runtime (a mixed-tuple/pack lowering bug). Passing
    ///   the prepended mutators as variadic arguments — `mutators: scheduleByteMutator,
    ///   repeat each userMutators` — lowers correctly.
    /// - Note: `scheduleBytesExtractor` is a *required* parameter on the
    ///   designated initializer (rather than defaulted) because a defaulted
    ///   pack-closure argument makes the compiler emit a default-argument
    ///   generator whose reabstraction thunk crashes SILGen. The non-scheduled
    ///   convenience initializer passes the no-op extractor as an explicit
    ///   closure literal, which lowers cleanly.
    init(
        mutators: repeat Mutator<each Input>,
        config: FuzzEngineConfig,
        coverageStrategy: CoverageStrategy<repeat each Input>,
        scheduleBytesExtractor: @escaping @Sendable ((repeat each Input)) -> [UInt8]?
    ) {
        self.config = config
        self.mutators = (repeat each mutators)
        self.inputSize = Self.inputCount(for: repeat (each Input).self)
        self.coverageStrategy = coverageStrategy
        self.scheduleBytesExtractor = scheduleBytesExtractor
    }

    /// Non-scheduled convenience initializer: runs over the user's pack with a
    /// no-op schedule-bytes extractor.
    convenience init(
        mutators: repeat Mutator<each Input>,
        config: FuzzEngineConfig = FuzzEngineConfig(),
        coverageStrategy: CoverageStrategy<repeat each Input> = .pathTrie
    ) {
        self.init(
            mutators: repeat each mutators,
            config: config,
            coverageStrategy: coverageStrategy,
            scheduleBytesExtractor: { _ in nil }
        )
    }

    // MARK: - Helpers

    /// Count the number of elements in a parameter pack.
    private static func inputCount(for input: repeat (each Input).Type) -> Int {
        var count = 0
        (repeat { _ = each input; count += 1 }())
        return count
    }

    // MARK: - Fuzzing

    /// Run the fuzzing engine over the given seeds.
    ///
    /// - Parameters:
    ///   - seeds: The inputs to start from. The caller assembles these (e.g. mutator
    ///     seed values plus domain-specific inputs, or a corpus to replay); the engine
    ///     runs exactly what it's given and generates further inputs by mutation.
    ///   - processSyncPlugins: Sync plugin processor for iteration events (hot path).
    ///   - processAsyncPlugins: Async plugin processor for rare events (cold path).
    ///   - test: The test closure to fuzz.
    /// - Returns: The fuzz result with corpus and any failures.
    func run(
        seeds: [InputTuple] = [],
        processSyncPlugins: @escaping SyncPluginProcessorFn,
        processAsyncPlugins: @escaping AsyncPluginProcessorFn,
        test: @escaping @Sendable (InputTuple) async throws -> Void
    ) async -> FuzzResult<repeat each Input> {
        // Filter compiler-generated edges before any measurement.
        // This is a one-time scan (~2s for large binaries), so we do it before
        // capturing startTime so it doesn't eat into the fuzz duration budget.
        SanCovCounters.applyEdgeFilter()
        if config.verbose {
            let filtered = SanCovCounters.filteredEdgeCount
            if filtered > 0 {
                print("[Fuzz] Filtered \(filtered) compiler-generated edges")
            }
        }

        let startTime = dateClient.now()

        // No global edge-hook install: the strategy's recorder (its measurement
        // half) is attached to this engine's measurement context during the
        // evaluator's setup phase, so concurrent engines never interfere.

        // Early exit if no seeds and no way to generate inputs
        if seeds.isEmpty {
            if config.verbose {
                print("[Fuzz] No seeds and no mutations possible - exiting early")
            }
            // A fuzz run with no seeds is not a regression — report it as such
            // rather than via `.empty` (which is flagged `wasRegression: true`).
            return FuzzResult(
                corpus: CorpusSnapshot<repeat each Input>(entries: [], coveredIndices: []),
                failures: [],
                stats: FuzzStats(
                    totalInputs: 0,
                    seeds: 0,
                    mutations: 0,
                    generations: 0,
                    duration: 0,
                    stopReason: .noSeedsAvailable
                ),
                wasRegression: false
            )
        }

        let corpus: Corpus<repeat each Input> = corpusRegistry.getCorpus()
        // Build a fresh evaluator per engine so each gets its own trie/index state.
        let coverageEvaluator: CoverageEvaluator<repeat each Input> = coverageStrategy.makeEvaluator()

        let stateMachine = FuzzStateMachine<repeat each Input>(
            seeds: seeds,
            mutators: mutators,
            inputSize: inputSize,
            corpus: corpus,
            coverageEvaluator: coverageEvaluator,
            processSyncPlugins: processSyncPlugins,
            processAsyncPlugins: processAsyncPlugins,
            config: config,
            startTime: startTime,
            test: test,
            scheduleBytesExtractor: scheduleBytesExtractor
        )

        let stateMachineResult = try! await stateMachine.start()

        // Extract copyable fields
        let stats = stateMachineResult.stats
        let failures = stateMachineResult.failures
        let resultCorpus = stateMachineResult.corpus

        let finalSnapshot = resultCorpus.snapshot()

        // Send .end event to plugins (for coverage gap analysis, etc.)
        let endContext = AsyncPluginEvent<repeat each Input>.EndContext(
            totalCoveredIndices: finalSnapshot.coveredIndices,
            projectPath: config.projectPath,
            sourceLocation: config.sourceLocation
        )
        await processAsyncPlugins(.end(endContext)) { action in
            self.executeEndAction(action)
        }

        return FuzzResult(
            corpus: finalSnapshot,
            failures: failures,
            stats: stats,
            wasRegression: false,
            campaignStopRequested: stateMachineResult.campaignStopRequested
        )
    }

    /// Execute plugin actions from .end event.
    private func executeEndAction(_ action: FuzzPluginAction<repeat each Input>) {
        switch action {
        case .recordIssue(let issueAction):
            Issue.record(issueAction.comment, sourceLocation: issueAction.sourceLocation)
        default:
            // Other actions not applicable at end time
            break
        }
    }
}

func runWithTimeout(
    timeout: Duration,
    _ task: @Sendable @escaping () async throws -> Void
) async rethrows -> Bool {
    @Dependency(\.continuousClockClient) var clock
    return try await withThrowingTaskGroup(of: Bool.self) { timeoutGroup in
        timeoutGroup.addTask {
            try await task()
            return false
        }
        timeoutGroup.addTask { [clock] in
            try await clock.sleep(for: timeout)
            return true
        }
        let didHang = try await timeoutGroup.next()
        timeoutGroup.cancelAll()
        return didHang ?? false
    }
}
