//
//  FuzzEngine+Config.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Foundation

extension FuzzEngine {
    /// Configuration for the fuzzing run.
    public struct Config: Sendable {
        /// Maximum iterations (inputs to test).
        public var maxIterations: Int

        /// Maximum time to spend fuzzing.
        public var maxDuration: TimeInterval

        /// Probability of generating fresh vs mutating (0.0-1.0).
        /// Higher = more fresh generation.
        public var generationRatio: Double

        /// Whether to minimize the corpus before saving.
        public var minimizeCorpus: Bool

        /// Verbose logging.
        public var verbose: Bool

        /// Controls how the fuzzer handles existing corpus files.
        /// Defaults to checking the `FUZZ_CORPUS_MODE` environment variable,
        /// then falling back to `.auto`.
        public var corpusMode: CorpusMode

        /// Per-input execution timeout in seconds.
        /// When set, each test execution will be terminated if it exceeds this duration.
        /// This catches infinite loops and deadlocks.
        /// Default: nil (no per-input timeout, only overall duration limit applies).
        ///
        /// Based on Miller 1990 "Fuzz" paper which used 5-minute timeouts to detect hangs.
        public var perInputTimeout: TimeInterval?

        /// Number of inputs to test in parallel during the mutation phase.
        /// Higher values increase parallelism but may reduce coverage guidance accuracy
        /// since corpus updates happen in batches rather than after each test.
        /// - 0: Use system processor count (default, ~50% faster than sequential)
        /// - 1: Sequential execution (best for shared mutable state)
        /// - N: Fixed batch size
        /// Default: 0 (processor count).
        public var mutationBatchSize: Int

        /// Project root path for filtering coverage gaps to project files only.
        /// When set, only reports gaps in files under this path.
        public var projectPath: String?

        // MARK: - Plugin Configuration

        /// Observer plugins that receive lifecycle notifications.
        /// These are called at various points during fuzzing but don't influence behavior.
        public var observerPlugins: [any FuzzObserverPlugin]

        /// Stopping condition plugins that determine when fuzzing should stop.
        /// Default: `[.plateauDetector()]` for adaptive early stopping.
        /// Pass an empty array to disable automatic stopping (only iteration/time limits apply).
        public var stoppingPlugins: [any StoppingConditionPlugin]

        /// Analysis plugins that run after fuzzing completes.
        /// Default: empty (no post-fuzzing analysis).
        /// Use `.coverageGaps()` to enable coverage gap detection.
        public var analysisPlugins: [any AnalysisPlugin]

        public init(
            maxIterations: Int = 10_000,
            maxDuration: TimeInterval = 60,
            generationRatio: Double = 0.3,
            minimizeCorpus: Bool = true,
            verbose: Bool = false,
            corpusMode: CorpusMode? = nil,
            perInputTimeout: TimeInterval? = nil,
            mutationBatchSize: Int = 0,
            projectPath: String? = nil,
            observerPlugins: [any FuzzObserverPlugin] = [],
            stoppingPlugins: [any StoppingConditionPlugin]? = nil,
            analysisPlugins: [any AnalysisPlugin] = []
        ) {
            self.maxIterations = maxIterations
            self.maxDuration = maxDuration
            self.generationRatio = generationRatio
            self.minimizeCorpus = minimizeCorpus
            self.verbose = verbose
            // Use provided mode, or check environment, or default to auto
            self.corpusMode = corpusMode ?? CorpusMode.fromEnvironment()
            self.perInputTimeout = perInputTimeout
            // 0 means "use processor count"
            self.mutationBatchSize = mutationBatchSize == 0
                ? ProcessInfo.processInfo.processorCount
                : max(1, mutationBatchSize)
            self.projectPath = projectPath
            self.observerPlugins = observerPlugins
            // Default to plateau detector for adaptive early stopping
            self.stoppingPlugins = stoppingPlugins ?? [
                PlateauDetectorPlugin(config: .init(
                    windowSize: max(1, min(500, maxIterations / 10)),
                    minDiscoveryRate: 0.001,
                    confirmationWindows: 3
                ))
            ]
            self.analysisPlugins = analysisPlugins
        }
    }
}
