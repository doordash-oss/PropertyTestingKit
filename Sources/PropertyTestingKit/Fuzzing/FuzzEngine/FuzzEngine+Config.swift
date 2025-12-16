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

        /// Configuration for adaptive early stopping based on coverage plateau detection.
        /// When nil, uses a simple iteration count-based approach.
        public var plateauConfig: CoveragePlateauDetector.Config

        /// Legacy: Stop after this many iterations without new coverage.
        /// Only used when plateauConfig is disabled.
        /// Deprecated: Use plateauConfig instead for more accurate plateau detection.
        public var plateauThreshold: Int

        /// Probability of generating fresh vs mutating (0.0-1.0).
        /// Higher = more fresh generation.
        public var generationRatio: Double

        /// Whether to minimize the corpus before saving.
        public var minimizeCorpus: Bool

        /// Verbose logging.
        public var verbose: Bool

        /// Enable value profile guidance for comparison tracking.
        /// Requires test code to be compiled with `-sanitize-coverage=trace-cmp`.
        public var enableValueProfile: Bool

        /// Enable string dictionary capture to discover magic strings at runtime.
        /// Captured strings are added to the mutation dictionary for String inputs.
        public var enableStringCapture: Bool

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

        /// Enable FairFuzz-style rare branch targeting.
        /// When enabled, preferentially selects and mutates inputs that hit
        /// rarely-covered branches, improving coverage uniformity.
        ///
        /// Based on Lemieux & Sen 2018 "FairFuzz" - achieved 10.6% more branch coverage.
        public var enableRareBranchTargeting: Bool

        /// Probability of selecting rare-branch-hitting inputs (0.0-1.0).
        /// Higher values focus more on rare branches; lower values maintain diversity.
        /// Default: 0.8 (80% chance of rare branch selection when available).
        public var rareBranchSelectionProbability: Double

        /// Number of mutations to test when targeting rare branches.
        /// Higher values explore more from rare-branch seeds.
        /// Default: 3 (test 3 mutations vs 1 normally).
        public var rareBranchMutationAmplification: Int

        /// Swarm testing configuration for mutator subset selection.
        /// When enabled, randomly enables/disables mutation strategies per time window.
        ///
        /// Based on Groce et al. 2012 "Swarm Testing" - found 42% more bugs.
        public var swarmConfig: SwarmConfig

        /// Adaptive mutation scheduling configuration (MOPT-style).
        /// When enabled, tracks which mutation strategies discover new coverage
        /// and dynamically adjusts selection probabilities.
        ///
        /// Based on Lyu et al. 2019 "MOPT" - found 170% more unique crashes than AFL.
        public var adaptiveMutationConfig: AdaptiveMutationConfig

        /// Enable coverage gap detection to identify partially-covered functions.
        /// When enabled, the fuzzer will report functions that have some coverage
        /// but not complete coverage, helping identify missing seeds or mutation strategies.
        /// Requires test code to be built with coverage instrumentation.
        public var detectCoverageGaps: Bool

        /// Configuration for coverage gap detection.
        public var coverageGapConfig: CoverageGapDetector.Config

        public init(
            maxIterations: Int = 10_000,
            maxDuration: TimeInterval = 60,
            plateauThreshold: Int = 1000,
            plateauConfig: CoveragePlateauDetector.Config? = nil,
            generationRatio: Double = 0.3,
            minimizeCorpus: Bool = true,
            verbose: Bool = false,
            enableValueProfile: Bool = true,
            enableStringCapture: Bool = true,
            corpusMode: CorpusMode? = nil,
            perInputTimeout: TimeInterval? = nil,
            enableRareBranchTargeting: Bool = false,
            rareBranchSelectionProbability: Double = 0.8,
            rareBranchMutationAmplification: Int = 3,
            swarmConfig: SwarmConfig = SwarmConfig(),
            adaptiveMutationConfig: AdaptiveMutationConfig = AdaptiveMutationConfig(),
            detectCoverageGaps: Bool = false,
            coverageGapConfig: CoverageGapDetector.Config = CoverageGapDetector.Config()
        ) {
            self.maxIterations = maxIterations
            self.maxDuration = maxDuration
            self.plateauThreshold = plateauThreshold
            // Default plateau config based on iterations
            self.plateauConfig = plateauConfig ?? CoveragePlateauDetector.Config(
                windowSize: max(1, min(500, maxIterations / 10)),
                minDiscoveryRate: 0.001,
                confirmationWindows: 3,
                enabled: true
            )
            self.generationRatio = generationRatio
            self.minimizeCorpus = minimizeCorpus
            self.verbose = verbose
            self.enableValueProfile = enableValueProfile
            self.enableStringCapture = enableStringCapture
            // Use provided mode, or check environment, or default to auto
            self.corpusMode = corpusMode ?? CorpusMode.fromEnvironment()
            self.perInputTimeout = perInputTimeout
            self.enableRareBranchTargeting = enableRareBranchTargeting
            self.rareBranchSelectionProbability = rareBranchSelectionProbability
            self.rareBranchMutationAmplification = rareBranchMutationAmplification
            self.swarmConfig = swarmConfig
            self.adaptiveMutationConfig = adaptiveMutationConfig
            self.detectCoverageGaps = detectCoverageGaps
            self.coverageGapConfig = coverageGapConfig
        }
    }
}
