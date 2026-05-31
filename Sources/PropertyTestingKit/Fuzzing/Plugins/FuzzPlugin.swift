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

//  Plugin events and actions for FuzzEngine.
//

import Testing
import Foundation

// MARK: - Sync Plugin Events (Hot Path)

/// Synchronous events dispatched to plugins during fuzzing.
/// These are called millions of times and must be handled synchronously.
public enum SyncPluginEvent<each T: Sendable>: Sendable {
    /// An iteration completed.
    case iteration(IterationContext)

    /// The mutation queue has drained.
    ///
    /// Dispatched the moment the pending-input queue becomes empty, *before*
    /// the engine falls back to generating a fresh random input. A handler can
    /// respond by stopping the run (`.stop`) — used for regression replay, where
    /// the corpus is loaded as seeds and the run ends once they're exhausted —
    /// or by refilling the queue (`.queueInputs` / `.selectForMutation`). If no
    /// handler does either, the engine proceeds to random generation as usual.
    case queueEmpty

    /// Context provided after each iteration.
    public struct IterationContext: Sendable {
        /// Whether this iteration discovered new coverage.
        public let discoveredNewCoverage: Bool
        /// The input that was tested in this iteration.
        public let input: (repeat each T)
        /// Whether this input came from the pending mutation queue (`true`)
        /// or was freshly generated (`false`). Plugins can use this to detect
        /// when the mutation queue has been exhausted and re-schedule corpus
        /// entries for mutation.
        public let fromMutationQueue: Bool
        /// The sparse coverage snapshot for this iteration.
        /// Only populated when `discoveredNewCoverage == true`; `nil` otherwise.
        public let sparseCoverage: SparseCoverage?

        public init(
            discoveredNewCoverage: Bool,
            input: consuming (repeat each T),
            fromMutationQueue: Bool = false,
            sparseCoverage: SparseCoverage? = nil
        ) {
            self.discoveredNewCoverage = discoveredNewCoverage
            self.input = input
            self.fromMutationQueue = fromMutationQueue
            self.sparseCoverage = sparseCoverage
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
        public let sparseCoverage: SparseCoverage

        public init(
            input: consuming (repeat each T),
            test: @Sendable @escaping ((repeat each T)) async throws -> Void,
            sourceLocation: SourceLocation,
            sparseCoverage: SparseCoverage
        ) {
            self.input = input
            self.test = test
            self.sourceLocation = sourceLocation
            self.sparseCoverage = sparseCoverage
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
        public let sparseCoverage: SparseCoverage
        public let entryType: CorpusEntryType
        public let failureInfo: FailureInfo?

        public init(
            input: consuming (repeat each T),
            sparseCoverage: SparseCoverage,
            entryType: CorpusEntryType,
            failureInfo: FailureInfo? = nil
        ) {
            self.input = input
            self.sparseCoverage = sparseCoverage
            self.entryType = entryType
            self.failureInfo = failureInfo
        }
    }
}
