//
//  FuzzResult.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//
import Foundation

/// The result of a fuzz test run.
public struct FuzzResult<each Input: Codable & Sendable>: Sendable {
    /// The final corpus after fuzzing/regression (as a snapshot for serialization).
    public let corpus: CorpusSnapshot<repeat each Input>

    /// Inputs that caused test failures.
    public let failures: [(input: (repeat each Input), error: Error)]

    /// Statistics about the fuzz run.
    public let stats: FuzzStats

    /// Whether this was a regression run (replaying saved corpus).
    public let wasRegression: Bool

    /// Inputs that had different coverage than expected (regression only).
    public let coverageChanges: [(input: (repeat each Input), expected: CoverageSignature, actual: CoverageSignature)]

    /// Reports from analysis plugins.
    public let analysisReports: [AnyAnalysisReport]

    /// Shrinking statistics for each failure (parallel array with failures).
    /// Only populated if shrinking was performed.
    public let shrinkingStats: [ShrinkStats]

    public init(
        corpus: CorpusSnapshot<repeat each Input>,
        failures: [(input: (repeat each Input), error: Error)],
        stats: FuzzStats,
        wasRegression: Bool,
        coverageChanges: [(input: (repeat each Input), expected: CoverageSignature, actual: CoverageSignature)],
        analysisReports: [AnyAnalysisReport] = [],
        shrinkingStats: [ShrinkStats] = []
    ) {
        self.corpus = corpus
        self.failures = failures
        self.stats = stats
        self.wasRegression = wasRegression
        self.coverageChanges = coverageChanges
        self.analysisReports = analysisReports
        self.shrinkingStats = shrinkingStats
    }

    /// Get a specific analysis report by plugin ID.
    public func analysisReport<R>(for pluginId: String, as type: R.Type) -> R? {
        analysisReports.first { $0.pluginId == pluginId }?.report(as: type)
    }

    /// Get the coverage gap report if gap detection was enabled.
    public var coverageGapReport: CoverageGapReport? {
        analysisReport(for: "coverageGaps", as: CoverageGapReport.self)
    }
}

/// Statistics about a fuzz run.
public struct FuzzStats: Sendable {
    /// Total inputs tested.
    public let totalInputs: Int

    /// New coverage paths discovered.
    public let newPaths: Int

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

    /// Plateau detection statistics (if available).
    public let plateauStats: PlateauStats?

    /// Number of inputs that caused test failures.
    public let failures: Int

    /// Number of inputs that timed out (potential hangs).
    public let hangs: Int

    /// Reason for stopping the fuzz run.
    public enum StopReason: String, Sendable {
        case iterationLimit = "iteration_limit"
        case timeLimit = "time_limit"
        case coveragePlateau = "coverage_plateau"
        case regression = "regression"
        case noSeedsAvailable = "no_seeds_available"
    }

    public init(
        totalInputs: Int,
        newPaths: Int,
        mutations: Int,
        generations: Int,
        duration: TimeInterval,
        stopReason: StopReason = .iterationLimit,
        plateauStats: PlateauStats? = nil,
        failures: Int = 0,
        hangs: Int = 0
    ) {
        self.totalInputs = totalInputs
        self.newPaths = newPaths
        self.mutations = mutations
        self.generations = generations
        self.duration = duration
        self.stopReason = stopReason
        self.plateauStats = plateauStats
        self.failures = failures
        self.hangs = hangs
    }
}
