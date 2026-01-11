//
//  EventBasedPlugin.swift
//  PropertyTestingKit
//
//  Unified event-based plugin system for FuzzEngine.
//

import Testing
import Foundation

// MARK: - Plugin Protocol

/// Protocol for event-based FuzzEngine plugins.
///
/// Plugins receive events from the fuzz engine and return actions to be executed.
/// Plugins run in array order - first plugin handles event first.
public protocol EventBasedPlugin: Sendable {
    /// Unique identifier for this plugin (for logging).
    var id: String { get }

    /// Handle an event and return actions to execute.
    ///
    /// - Parameter event: The plugin event to handle.
    /// - Returns: Actions for FuzzEngine to execute.
    func handle<each T: Sendable>(
        event: PluginEvent<repeat each T>
    ) async throws -> [FuzzPluginAction<repeat each T>]
}

// MARK: - Plugin Events

/// Events dispatched to plugins during fuzzing.
public enum PluginEvent<each T: Sendable>: Sendable {
    /// Fuzzing is starting.
    case start(StartContext)

    /// Fuzzing has ended.
    case end(EndContext)

    /// A test failure was found.
    case failureFound(FailureFoundContext)

    /// A hang was detected.
    case hangDetected(HangDetectedContext)

    /// An iteration completed.
    case iteration(IterationContext)

    /// A batch of iterations completed.
    case batchComplete(BatchContext)

    // MARK: - Context Types

    /// Context provided when fuzzing starts.
    public struct StartContext: Sendable {
        /// Maximum number of iterations configured.
        public let maxIterations: Int
        /// Maximum duration in seconds.
        public let maxDuration: Duration
        /// Number of inputs per batch.
        public let batchSize: Int
        /// How the corpus is being handled.
        public let corpusMode: CorpusMode
        /// Number of seed inputs.
        public let seedCount: Int

        public init(
            maxIterations: Int,
            maxDuration: Duration,
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
        /// Set of all covered edge indices.
        public let totalCoveredIndices: Set<Int>
        /// Project path for filtering (if configured).
        public let projectPath: String?
        /// Source location of the fuzz call (nil when not available, e.g. in tests).
        public let sourceLocation: SourceLocation?

        public init(
            totalIterations: Int,
            duration: TimeInterval,
            corpusSize: Int,
            failureCount: Int,
            hangCount: Int,
            stopReason: FuzzStats.StopReason,
            totalCoveredIndices: Set<Int>,
            projectPath: String?,
            sourceLocation: SourceLocation? = nil
        ) {
            self.totalIterations = totalIterations
            self.duration = duration
            self.corpusSize = corpusSize
            self.failureCount = failureCount
            self.hangCount = hangCount
            self.stopReason = stopReason
            self.totalCoveredIndices = totalCoveredIndices
            self.projectPath = projectPath
            self.sourceLocation = sourceLocation
        }
    }

    /// Context provided when a test failure is found.
    public struct FailureFoundContext: @unchecked Sendable {
        /// The input that caused the failure.
        public let input: (repeat each T)
        /// The test closure for shrinking attempts.
        public let test: @Sendable ((repeat each T)) async throws -> Void
        /// Description of the failure.
        public let failure: String
        /// Source location where the fuzz test was called.
        public let sourceLocation: SourceLocation

        public init(
            input: (repeat each T),
            test: @Sendable @escaping ((repeat each T)) async throws -> Void,
            failure: String,
            sourceLocation: SourceLocation
        ) {
            self.input = input
            self.test = test
            self.failure = failure
            self.sourceLocation = sourceLocation
        }
    }

    /// Context provided when a hang is detected.
    public struct HangDetectedContext: @unchecked Sendable {
        /// The input that caused the hang.
        public let input: (repeat each T)
        /// The timeout duration that was exceeded.
        public let timeout: Duration

        public init(input: (repeat each T), timeout: Duration) {
            self.input = input
            self.timeout = timeout
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
        /// Current corpus size.
        public let corpusSize: Int

        public init(
            iteration: Int,
            discoveredNewCoverage: Bool,
            elapsed: TimeInterval,
            corpusSize: Int
        ) {
            self.iteration = iteration
            self.discoveredNewCoverage = discoveredNewCoverage
            self.elapsed = elapsed
            self.corpusSize = corpusSize
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
}

// MARK: - Plugin Actions

/// Actions that plugins can return for FuzzEngine to execute.
public enum FuzzPluginAction<each T: Sendable>: Sendable {
    /// Stop fuzzing.
    case stop(StopAction)
    /// Record an issue to Swift Testing.
    case recordIssue(IssueAction)
    /// Add inputs to the mutation queue.
    case queueInputs(QueueInputsAction)
    /// Select an input for mutation (e.g., shrunk input).
    case selectForMutation(SelectForMutationAction)
    /// Submit an input to the corpus.
    case submitToCorpus(SubmitToCorpusAction)

    /// Action to stop fuzzing.
    public struct StopAction: Sendable {
        /// Reason for stopping.
        public let reason: String

        public init(reason: String) {
            self.reason = reason
        }
    }

    /// Action to record an issue.
    public struct IssueAction: Sendable {
        /// The issue comment/message.
        public let comment: Comment
        /// Source location for the issue.
        public let sourceLocation: SourceLocation

        public init(comment: Comment, sourceLocation: SourceLocation) {
            self.comment = comment
            self.sourceLocation = sourceLocation
        }
    }

    /// Action to queue inputs for mutation.
    public struct QueueInputsAction: Sendable {
        /// Encoded inputs to add to the mutation queue.
        public let inputs: [Data]

        public init(inputs: [Data]) {
            self.inputs = inputs
        }
    }

    /// Action to select an input for mutation.
    public struct SelectForMutationAction: @unchecked Sendable {
        /// The input to select for mutation.
        public let input: (repeat each T)

        public init(input: (repeat each T)) {
            self.input = input
        }
    }

    /// Action to submit an input to the corpus.
    public struct SubmitToCorpusAction: @unchecked Sendable {
        /// The input to submit to the corpus.
        public let input: (repeat each T)

        public init(input: (repeat each T)) {
            self.input = input
        }
    }
}
