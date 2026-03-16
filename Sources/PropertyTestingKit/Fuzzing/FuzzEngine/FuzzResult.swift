//
//  FuzzResult.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//
import Foundation
import Dependencies

/// The result of a fuzz test run.
public struct FuzzResult<each Input: Codable & Sendable>: Sendable {
    /// The final corpus after fuzzing/regression (as a snapshot for serialization).
    public let corpus: CorpusSnapshot<repeat each Input>

    /// Inputs that caused test failures.
    public let failures: [(input: (repeat each Input), error: Error, timeElapsed: TimeInterval)]

    /// Statistics about the fuzz run.
    public let stats: FuzzStats

    /// Whether this was a regression run (replaying saved corpus).
    public let wasRegression: Bool

    /// Inputs that had different coverage than expected (regression only).
    public let coverageChanges: [(input: (repeat each Input), expected: SparseCoverage, actual: SparseCoverage)]

    public init(
        corpus: CorpusSnapshot<repeat each Input>,
        failures: [(input: (repeat each Input), error: Error, timeElapsed: TimeInterval)],
        stats: FuzzStats,
        wasRegression: Bool,
        coverageChanges: [(input: (repeat each Input), expected: SparseCoverage, actual: SparseCoverage)]
    ) {
        self.corpus = corpus
        self.failures = failures
        self.stats = stats
        self.wasRegression = wasRegression
        self.coverageChanges = coverageChanges
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
        case regression
        case noSeedsAvailable
        case custom(String)

        public init?(rawValue: String) {
            switch rawValue {
            case "time_limit": self = .timeLimit
            case "regression": self = .regression
            case "no_seeds_available": self = .noSeedsAvailable
            default: self = .custom(rawValue)
            }
        }

        public var rawValue: String {
            switch self {
            case .timeLimit: "time_limit"
            case .regression: "regression"
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
            stopReason: .regression,
        )
        return FuzzResult(
            corpus: emptySnapshot,
            failures: [],
            stats: emptyStats,
            wasRegression: true,
            coverageChanges: []
        )
    }
}
