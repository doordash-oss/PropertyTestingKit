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

import Foundation
import Dependencies

/// The result of a fuzz test run.
public struct FuzzResult<each Input: Codable & Sendable>: Sendable {
    /// The final corpus after fuzzing/regression (as a snapshot for serialization).
    public let corpus: CorpusSnapshot<repeat each Input>

    /// Inputs that caused test failures.
    public let failures: [(input: (repeat each Input), error: Error, timeElapsed: TimeInterval, scheduleBytes: [UInt8]?)]

    /// Statistics about the fuzz run.
    public let stats: FuzzStats

    /// Whether this was a regression run (replaying saved corpus).
    public let wasRegression: Bool

    /// A plugin requested a campaign-wide stop (`StopScope.campaign`) — e.g. the
    /// run found its first counterexample. In a parallel run this is what tells
    /// the coordinator to cancel the sibling engines.
    public let campaignStopRequested: Bool

    public init(
        corpus: CorpusSnapshot<repeat each Input>,
        failures: [(input: (repeat each Input), error: Error, timeElapsed: TimeInterval, scheduleBytes: [UInt8]?)],
        stats: FuzzStats,
        wasRegression: Bool,
        campaignStopRequested: Bool = false
    ) {
        self.corpus = corpus
        self.failures = failures
        self.stats = stats
        self.wasRegression = wasRegression
        self.campaignStopRequested = campaignStopRequested
    }
}

/// Statistics about a fuzz run.
public struct FuzzStats: Sendable {
    /// Total inputs tested.
    public let totalInputs: Int

    /// Number of mutations performed.
    public let mutations: Int

    /// Number of fresh generations.
    public let generations: Int

    /// Time spent fuzzing.
    public let duration: TimeInterval

    /// Inputs per second.
    public var inputsPerSecond: Double {
        duration > 0 ? Double(totalInputs) / duration : 0
    }

    /// Why fuzzing stopped.
    public let stopReason: StopReason

    /// Number of inputs that caused test failures.
    public let failures: Int

    /// Reason for stopping the fuzz run.
    public enum StopReason: RawRepresentable, Sendable {
        case timeLimit
        /// The run replayed every queued input and stopped because the queue drained —
        /// e.g. a regression replay finished. This is a normal completion, not a failure.
        case regressionTestCompleted
        case noSeedsAvailable
        case custom(String)

        public init?(rawValue: String) {
            switch rawValue {
            case "time_limit": self = .timeLimit
            case "regression_test_completed": self = .regressionTestCompleted
            case "no_seeds_available": self = .noSeedsAvailable
            default: self = .custom(rawValue)
            }
        }

        public var rawValue: String {
            switch self {
            case .timeLimit: "time_limit"
            case .regressionTestCompleted: "regression_test_completed"
            case .noSeedsAvailable: "no_seeds_available"
            case let .custom(reason): reason
            }
        }
    }

    public init(
        totalInputs: Int,
        mutations: Int,
        generations: Int,
        duration: TimeInterval,
        stopReason: StopReason = .timeLimit,
        failures: Int = 0,
    ) {
        self.totalInputs = totalInputs
        self.mutations = mutations
        self.generations = generations
        self.duration = duration
        self.stopReason = stopReason
        self.failures = failures
    }
}

extension FuzzResult {
    static var empty: Self {
        @Dependency(\.dateClient) var dateClient

        let emptySnapshot = CorpusSnapshot<repeat each Input>(
            entries: [],
            coveredIndices: []
        )
        let emptyStats = FuzzStats(
            totalInputs: 0,
            mutations: 0,
            generations: 0,
            duration: 0,
            stopReason: .regressionTestCompleted,
        )
        return FuzzResult(
            corpus: emptySnapshot,
            failures: [],
            stats: emptyStats,
            wasRegression: true
        )
    }
}
