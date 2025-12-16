//
//  FuzzResult.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//
import Foundation

/// The result of a fuzz test run.
public struct FuzzResult<each Input: Codable & Sendable>: Sendable {
    /// The final corpus after fuzzing/regression.
    public let corpus: Corpus<repeat each Input>

    /// Inputs that caused test failures.
    public let failures: [(input: (repeat each Input), error: Error)]

    /// Statistics about the fuzz run.
    public let stats: FuzzStats

    /// Whether this was a regression run (replaying saved corpus).
    public let wasRegression: Bool

    /// Inputs that had different coverage than expected (regression only).
    public let coverageChanges: [(input: (repeat each Input), expected: CoverageSignature, actual: CoverageSignature)]

    /// Coverage gaps detected (only populated if `detectCoverageGaps` was enabled).
    /// Reports functions that have partial coverage - some regions executed, some not.
    public let coverageGapReport: CoverageGapReport?
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
        case legacyPlateau = "legacy_plateau"
        case regression = "regression"
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

/// Error indicating that a test execution timed out (potential infinite loop or deadlock).
///
/// Based on Miller 1990 "Fuzz" paper which introduced timeout-based hang detection.
public struct HangDetectedError: Error, LocalizedError, Sendable {
    /// The timeout duration that was exceeded.
    public let timeout: TimeInterval

    public var errorDescription: String? {
        "Test execution timed out after \(String(format: "%.2f", timeout)) seconds (potential hang)"
    }
}
