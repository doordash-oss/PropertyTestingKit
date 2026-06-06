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

    /// Context provided after each iteration.
    public struct IterationContext: Sendable {
        /// The input that was tested in this iteration.
        public let input: (repeat each T)
        /// Schedule bytes used for this iteration's task ordering.
        /// Non-nil when schedule fuzzing is enabled.
        public let scheduleBytes: [UInt8]?
        /// Whether this input came from the pending mutation queue (`true`)
        /// or was freshly generated (`false`). Plugins can use this to detect
        /// when the mutation queue has been exhausted and re-schedule corpus
        /// entries for mutation.
        public let fromMutationQueue: Bool
        /// Number of inputs still queued after this one was taken. A handler can
        /// use `queueCount == 0` to detect that the queue has drained — e.g. to
        /// stop a regression replay once the seeded corpus is exhausted.
        public let queueCount: Int
        /// The new coverage this iteration discovered, or `nil` if it covered
        /// nothing new. A non-nil value *is* the "discovered new coverage" signal.
        public let newCoverage: SparseCoverage?

        public init(
            input: consuming (repeat each T),
            scheduleBytes: [UInt8]? = nil,
            fromMutationQueue: Bool = false,
            queueCount: Int = 0,
            newCoverage: SparseCoverage? = nil
        ) {
            self.input = input
            self.scheduleBytes = scheduleBytes
            self.fromMutationQueue = fromMutationQueue
            self.queueCount = queueCount
            self.newCoverage = newCoverage
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

        public init(
            maxDuration: Duration
        ) {
            self.maxDuration = maxDuration
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
        /// Schedule bytes used for this iteration's task ordering.
        public let scheduleBytes: [UInt8]?
        /// The test closure for shrinking attempts.
        public let test: @Sendable ((repeat each T)) async throws -> Void
        /// Source location where the fuzz test was called.
        public let sourceLocation: SourceLocation
        public let sparseCoverage: SparseCoverage

        public init(
            input: consuming (repeat each T),
            scheduleBytes: [UInt8]? = nil,
            test: @Sendable @escaping ((repeat each T)) async throws -> Void,
            sourceLocation: SourceLocation,
            sparseCoverage: SparseCoverage
        ) {
            self.input = input
            self.scheduleBytes = scheduleBytes
            self.test = test
            self.sourceLocation = sourceLocation
            self.sparseCoverage = sparseCoverage
        }
    }
}

enum PluginEvent<each T: Sendable>: Sendable {
    case sync(SyncPluginEvent<repeat each T>)
    case async(AsyncPluginEvent<repeat each T>)
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
        /// Schedule bytes for each queued input (parallel array).
        public let scheduleBytes: [[UInt8]?]

        public init(inputs: consuming [(repeat each T)], scheduleBytes: [[UInt8]?] = []) {
            self.inputs = inputs
            self.scheduleBytes = scheduleBytes
        }
    }

    /// Action to select an input for mutation.
    public struct SelectForMutationAction: Sendable {
        /// The input to select for mutation.
        public let input: (repeat each T)
        /// Schedule bytes to mutate alongside the input.
        public let scheduleBytes: [UInt8]?

        public init(input: consuming (repeat each T), scheduleBytes: [UInt8]? = nil) {
            self.input = input
            self.scheduleBytes = scheduleBytes
        }
    }

    /// Action to submit an input to the corpus.
    public struct SubmitToCorpusAction: Sendable {
        /// The input to submit to the corpus.
        public let input: (repeat each T)
        /// Schedule bytes for this corpus entry.
        public let scheduleBytes: [UInt8]?
        public let sparseCoverage: SparseCoverage
        public let entryType: CorpusEntryType
        public let failureInfo: FailureInfo?

        public init(
            input: consuming (repeat each T),
            scheduleBytes: [UInt8]? = nil,
            sparseCoverage: SparseCoverage,
            entryType: CorpusEntryType,
            failureInfo: FailureInfo? = nil
        ) {
            self.input = input
            self.scheduleBytes = scheduleBytes
            self.sparseCoverage = sparseCoverage
            self.entryType = entryType
            self.failureInfo = failureInfo
        }
    }
}

// MARK: - Analysis Actions (regression-valid subset)

/// The subset of `FuzzPluginAction` that is valid during a regression replay.
///
/// A replay runs a fixed set of inputs (the saved corpus) and treats the on-disk
/// corpus as authoritative, so the only meaningful actions are *control* and
/// *observation* — `stop` and `recordIssue`. The *write* actions that mutate the
/// run (`queueInputs`, `selectForMutation`, `submitToCorpus`) are deliberately
/// absent: a handler typed to emit `AnalysisAction` literally cannot name them, so
/// `regress(...)` can only ever be handed plugins that emit valid actions. This is
/// the compile-time guarantee — there is no runtime gate.
///
/// The payloads are reused from `FuzzPluginAction` so there is one source of truth
/// and `lifted()` is a pure re-tag with no copying.
public enum AnalysisAction<each T: Sendable>: Sendable {
    /// Stop the run.
    case stop(FuzzPluginAction<repeat each T>.StopAction)
    /// Record an issue to Swift Testing.
    case recordIssue(FuzzPluginAction<repeat each T>.IssueAction)

    /// Widen this analysis action into the full `FuzzPluginAction`. Total and
    /// lossless — the only direction that exists. There is intentionally no
    /// `FuzzPluginAction -> AnalysisAction`, since that would be the partial,
    /// write-discarding direction this type is designed to forbid.
    @inlinable
    public func lifted() -> FuzzPluginAction<repeat each T> {
        switch self {
        case .stop(let action): return .stop(action)
        case .recordIssue(let action): return .recordIssue(action)
        }
    }
}
