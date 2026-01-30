//
//  FuzzPlugin.swift
//  PropertyTestingKit
//
//  Unified plugin system for FuzzEngine.
//

import Testing
import Foundation

// MARK: - Plugin Protocol

/// Protocol for FuzzEngine plugins.
///
/// Plugins receive events from the fuzz engine and return actions to be executed.
/// Plugins run in array order - first plugin handles event first.
///
/// The protocol has two handler methods:
/// - `handle(event:)` - Synchronous, called for iteration events (hot path, millions of calls)
/// - `handleAsync(event:)` - Asynchronous, called for rare events (start, end, failureFound)
///
/// Default implementations return empty arrays, so plugins only need to implement
/// the methods for events they care about.
public protocol FuzzPlugin: Sendable {
    /// Unique identifier for this plugin (for logging).
    var id: String { get }

    /// Handle a synchronous event and return actions to execute.
    ///
    /// This is the hot path - called millions of times per fuzz run.
    /// Must be synchronous to avoid async overhead.
    ///
    /// - Parameter event: The sync plugin event to handle (iteration events).
    /// - Returns: Actions for FuzzEngine to execute.
    func handle<each T: Sendable>(
        event: SyncPluginEvent<repeat each T>
    ) -> [FuzzPluginAction<repeat each T>]

    /// Handle an asynchronous event and return actions to execute.
    ///
    /// Called for rare events like start, end, and failureFound.
    /// Async is acceptable here since these events happen infrequently.
    ///
    /// - Parameter event: The async plugin event to handle.
    /// - Returns: Actions for FuzzEngine to execute.
    func handleAsync<each T: Sendable>(
        event: AsyncPluginEvent<repeat each T>
    ) async throws -> [FuzzPluginAction<repeat each T>]
}

// MARK: - Default Implementations

extension FuzzPlugin {
    /// Default implementation: do nothing for sync events.
    public func handle<each T: Sendable>(
        event: SyncPluginEvent<repeat each T>
    ) -> [FuzzPluginAction<repeat each T>] {
        return []
    }

    /// Default implementation: do nothing for async events.
    public func handleAsync<each T: Sendable>(
        event: AsyncPluginEvent<repeat each T>
    ) async throws -> [FuzzPluginAction<repeat each T>] {
        return []
    }
}

// MARK: - Sync Plugin Events (Hot Path)

/// Synchronous events dispatched to plugins during fuzzing.
/// These are called millions of times and must be handled synchronously.
public enum SyncPluginEvent<each T: Sendable>: Sendable {
    /// An iteration completed.
    case iteration(IterationContext)

    /// Context provided after each iteration.
    public struct IterationContext: Sendable {
        /// Whether this iteration discovered new coverage.
        public let discoveredNewCoverage: Bool
        /// The input that was tested in this iteration.
        public let input: (repeat each T)

        public init(
            discoveredNewCoverage: Bool,
            input: consuming (repeat each T)
        ) {
            self.discoveredNewCoverage = discoveredNewCoverage
            self.input = input
        }
    }
}

// MARK: - Async Plugin Events (Cold Path)

/// Asynchronous events dispatched to plugins during fuzzing.
/// These are called rarely and can be handled asynchronously.
public enum AsyncPluginEvent<each T: Sendable>: Sendable {
    /// Fuzzing is starting.
    case start(StartContext)

    /// Fuzzing has ended.
    case end(EndContext)

    /// A test failure was found.
    case failureFound(FailureFoundContext)

    /// Context provided when fuzzing starts.
    public struct StartContext: Sendable {
        /// Maximum duration in seconds.
        public let maxDuration: Duration
        /// How the corpus is being handled.
        public let corpusMode: CorpusMode

        public init(
            maxDuration: Duration,
            corpusMode: CorpusMode
        ) {
            self.maxDuration = maxDuration
            self.corpusMode = corpusMode
        }
    }

    /// Context provided when fuzzing ends.
    public struct EndContext: Sendable {
        /// Set of all covered edge indices.
        public let totalCoveredIndices: Set<UInt32>
        /// Project path for filtering (if configured).
        public let projectPath: String?
        /// Source location of the fuzz call.
        public let sourceLocation: SourceLocation

        public init(
            totalCoveredIndices: Set<UInt32>,
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
            input: consuming (repeat each T),
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
}

// MARK: - Legacy PluginEvent (for compatibility during migration)

/// Combined event type - deprecated, use SyncPluginEvent or AsyncPluginEvent instead.
@available(*, deprecated, message: "Use SyncPluginEvent for iteration events or AsyncPluginEvent for other events")
public enum PluginEvent<each T: Sendable>: Sendable {
    case start(AsyncPluginEvent<repeat each T>.StartContext)
    case end(AsyncPluginEvent<repeat each T>.EndContext)
    case failureFound(AsyncPluginEvent<repeat each T>.FailureFoundContext)
    case iteration(SyncPluginEvent<repeat each T>.IterationContext)
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

        public init(inputs: consuming [(repeat each T)]) {
            self.inputs = inputs
        }
    }

    /// Action to select an input for mutation.
    public struct SelectForMutationAction: Sendable {
        /// The input to select for mutation.
        public let input: (repeat each T)

        public init(input: consuming (repeat each T)) {
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
            input: consuming (repeat each T),
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
