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

    /// An iteration completed.
    case iteration(IterationContext)

    // MARK: - Context Types

    /// Context provided when fuzzing starts.
    public struct StartContext: Sendable {
        /// Maximum number of iterations configured.
        public let maxIterations: Int
        /// Maximum duration in seconds.
        public let maxDuration: Duration
        /// How the corpus is being handled.
        public let corpusMode: CorpusMode

        public init(
            maxIterations: Int,
            maxDuration: Duration,
            corpusMode: CorpusMode
        ) {
            self.maxIterations = maxIterations
            self.maxDuration = maxDuration
            self.corpusMode = corpusMode
        }
    }

    /// Context provided when fuzzing ends.
    public struct EndContext: Sendable {
        /// Set of all covered edge indices.
        public let totalCoveredIndices: Set<Int>
        /// Project path for filtering (if configured).
        public let projectPath: String?
        /// Source location of the fuzz call.
        public let sourceLocation: SourceLocation

        public init(
            totalCoveredIndices: Set<Int>,
            projectPath: String?,
            sourceLocation: SourceLocation
        ) {
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
        /// Source location where the fuzz test was called.
        public let sourceLocation: SourceLocation
        public let coverageSignature: CoverageSignature

        public init(
            input: (repeat each T),
            test: @Sendable @escaping ((repeat each T)) async throws -> Void,
            sourceLocation: SourceLocation,
            coverageSignature: CoverageSignature
        ) {
            self.input = input
            self.test = test
            self.sourceLocation = sourceLocation
            self.coverageSignature = coverageSignature
        }
    }

    /// Context provided after each iteration.
    public struct IterationContext: Sendable {
        /// Whether this iteration discovered new coverage.
        public let discoveredNewCoverage: Bool

        public init(
            discoveredNewCoverage: Bool
        ) {
            self.discoveredNewCoverage = discoveredNewCoverage
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
        public let reason: FuzzStats.StopReason

        public init(reason: FuzzStats.StopReason) {
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
        public let inputs: [(repeat each T)]

        public init(inputs: [(repeat each T)]) {
            self.inputs = inputs
        }
    }

    /// Action to select an input for mutation.
    public struct SelectForMutationAction: Sendable {
        /// The input to select for mutation.
        public let input: (repeat each T)

        public init(input: (repeat each T)) {
            self.input = input
        }
    }

    /// Action to submit an input to the corpus.
    public struct SubmitToCorpusAction: Sendable {
        /// The input to submit to the corpus.
        public let input: (repeat each T)
        public let coverageSignature: CoverageSignature
        public let entryType: CorpusEntryType
        public let failureInfo: FailureInfo?

        public init(
            input: (repeat each T),
            coverageSignature: CoverageSignature,
            entryType: CorpusEntryType,
            failureInfo: FailureInfo? = nil
        ) {
            self.input = input
            self.coverageSignature = coverageSignature
            self.entryType = entryType
            self.failureInfo = failureInfo
        }
    }
}
