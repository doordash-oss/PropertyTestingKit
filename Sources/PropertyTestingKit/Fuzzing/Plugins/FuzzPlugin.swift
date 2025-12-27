//
//  FuzzPlugin.swift
//  PropertyTestingKit
//
//  Base protocol for FuzzEngine plugins.
//

import Foundation

// MARK: - Base Plugin Protocol

/// Base protocol for all FuzzEngine plugins.
/// All plugins must be Sendable for thread safety in concurrent fuzzing.
public protocol FuzzPlugin: Sendable {
    /// Unique identifier for this plugin (for logging and report keying).
    var id: String { get }

    /// Priority for plugin execution order (higher = runs first).
    /// Default is 0.
    var priority: Int { get }
}

extension FuzzPlugin {
    public var priority: Int { 0 }
}

// MARK: - Plugin Context Types

/// Namespace for plugin context types.
/// These immutable structs are passed to plugin methods to provide
/// information about the current fuzzing state.
public enum FuzzPluginContext {

    /// Context provided when fuzzing starts.
    public struct StartContext: Sendable {
        /// Maximum number of iterations configured.
        public let maxIterations: Int
        /// Maximum duration in seconds.
        public let maxDuration: TimeInterval
        /// Number of inputs per batch.
        public let batchSize: Int
        /// How the corpus is being handled.
        public let corpusMode: CorpusMode
        /// Number of seed inputs.
        public let seedCount: Int

        public init(
            maxIterations: Int,
            maxDuration: TimeInterval,
            batchSize: Int,
            corpusMode: CorpusMode,
            seedCount: Int
        ) {
            self.maxIterations = maxIterations
            self.maxDuration = maxDuration
            self.batchSize = batchSize
            self.corpusMode = corpusMode
            self.seedCount = seedCount
        }
    }

    /// Context provided after each iteration.
    public struct IterationContext: Sendable {
        /// Current iteration number (0-based).
        public let iteration: Int
        /// Whether this iteration discovered new coverage.
        public let discoveredNewCoverage: Bool
        /// Time elapsed since fuzzing started.
        public let elapsed: TimeInterval

        public init(
            iteration: Int,
            discoveredNewCoverage: Bool,
            elapsed: TimeInterval
        ) {
            self.iteration = iteration
            self.discoveredNewCoverage = discoveredNewCoverage
            self.elapsed = elapsed
        }
    }

    /// Context provided after a batch of tests completes.
    public struct BatchContext: Sendable {
        /// Index of this batch (0-based).
        public let batchIndex: Int
        /// Number of inputs in this batch.
        public let batchSize: Int
        /// Number of new coverage paths discovered in this batch.
        public let newPathsInBatch: Int
        /// Total number of entries in the corpus.
        public let totalCorpusSize: Int
        /// Time elapsed since fuzzing started.
        public let elapsed: TimeInterval
        /// Number of failures found so far.
        public let failureCount: Int
        /// Number of hangs detected so far.
        public let hangCount: Int

        public init(
            batchIndex: Int,
            batchSize: Int,
            newPathsInBatch: Int,
            totalCorpusSize: Int,
            elapsed: TimeInterval,
            failureCount: Int,
            hangCount: Int
        ) {
            self.batchIndex = batchIndex
            self.batchSize = batchSize
            self.newPathsInBatch = newPathsInBatch
            self.totalCorpusSize = totalCorpusSize
            self.elapsed = elapsed
            self.failureCount = failureCount
            self.hangCount = hangCount
        }
    }

    /// Context for stopping condition checks.
    public struct StoppingContext: Sendable {
        /// Current iteration number.
        public let iteration: Int
        /// Time elapsed since fuzzing started.
        public let elapsed: TimeInterval
        /// Number of entries in the corpus.
        public let corpusSize: Int
        /// Recent discovery rate (discoveries per iteration in recent window).
        public let recentDiscoveryRate: Double
        /// Total number of coverage discoveries.
        public let totalDiscoveries: Int
        /// Iterations since the last coverage discovery.
        public let iterationsSinceLastDiscovery: Int

        public init(
            iteration: Int,
            elapsed: TimeInterval,
            corpusSize: Int,
            recentDiscoveryRate: Double,
            totalDiscoveries: Int,
            iterationsSinceLastDiscovery: Int
        ) {
            self.iteration = iteration
            self.elapsed = elapsed
            self.corpusSize = corpusSize
            self.recentDiscoveryRate = recentDiscoveryRate
            self.totalDiscoveries = totalDiscoveries
            self.iterationsSinceLastDiscovery = iterationsSinceLastDiscovery
        }
    }

    /// Context provided when fuzzing ends.
    public struct EndContext: Sendable {
        /// Total iterations completed.
        public let totalIterations: Int
        /// Total duration of fuzzing.
        public let duration: TimeInterval
        /// Final corpus size.
        public let corpusSize: Int
        /// Number of failures found.
        public let failureCount: Int
        /// Number of hangs detected.
        public let hangCount: Int
        /// Reason fuzzing stopped.
        public let stopReason: FuzzStats.StopReason

        public init(
            totalIterations: Int,
            duration: TimeInterval,
            corpusSize: Int,
            failureCount: Int,
            hangCount: Int,
            stopReason: FuzzStats.StopReason
        ) {
            self.totalIterations = totalIterations
            self.duration = duration
            self.corpusSize = corpusSize
            self.failureCount = failureCount
            self.hangCount = hangCount
            self.stopReason = stopReason
        }
    }

    /// Context for analysis plugins during post-processing.
    public struct AnalysisContext: Sendable {
        /// Set of all covered edge indices.
        public let totalCoveredIndices: Set<Int>
        /// Final corpus size.
        public let corpusSize: Int
        /// Total duration of fuzzing.
        public let duration: TimeInterval
        /// Project path for filtering (if configured).
        public let projectPath: String?

        public init(
            totalCoveredIndices: Set<Int>,
            corpusSize: Int,
            duration: TimeInterval,
            projectPath: String?
        ) {
            self.totalCoveredIndices = totalCoveredIndices
            self.corpusSize = corpusSize
            self.duration = duration
            self.projectPath = projectPath
        }
    }
}
