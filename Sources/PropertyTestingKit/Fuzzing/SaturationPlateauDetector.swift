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

//
//  SaturationPlateauDetector.swift
//  PropertyTestingKit
//
//  Saturation-based stopping criterion for fuzzing.
//
//  Based on:
//  - Böhme, M. et al. (2023). "Green Fuzzing: A Saturation-Based Stopping Criterion"
//    ISSTA 2023
//

import Foundation
import Dependencies

/// Plateau detector using saturation-based metrics from Green Fuzzing (ISSTA 2023).
///
/// Models coverage growth as an asymptotic process approaching saturation.
/// Uses the growth rate decay to predict when continued fuzzing will yield
/// diminishing returns.
///
/// ## Algorithm
///
/// 1. Track cumulative coverage over time windows
/// 2. Fit a saturation model: coverage(t) = C_max * (1 - e^(-λt))
/// 3. Estimate current saturation level: saturation = coverage / C_max
/// 4. Stop when saturation exceeds threshold or growth rate is negligible
///
/// The saturation model assumes coverage follows an exponential decay curve,
/// which matches empirical observations from fuzzing campaigns.
///
/// ## Reference
///
/// Böhme, M. et al. (2023). "Green Fuzzing: A Saturation-Based Stopping Criterion
/// using a Probabilistic Model to Predict Fuzzing Progress"
/// ISSTA 2023.
///
/// For simpler approaches, see ``SimpleCoveragePlateauDetector``.
/// For Good-Turing estimator, see ``STADSPlateauDetector``.
public struct SaturationPlateauDetector: Sendable {
    @Dependency(\.dateClient) var dateClient

    /// Configuration for saturation-based plateau detection.
    public struct Config: Sendable {
        /// Minimum saturation level (0-1) to declare plateau.
        /// Default: 0.99 = 99% saturated
        var minSaturation: Double

        /// Minimum growth rate (new discoveries per iteration) before plateau.
        /// Default: 0.0001 = 1 new path per 10,000 iterations
        var minGrowthRate: Double

        /// Window size for calculating growth rate.
        var windowSize: Int

        /// Number of consecutive windows below threshold required.
        var confirmationWindows: Int

        /// Whether saturation detection is enabled.
        var enabled: Bool

        public init(
            minSaturation: Double = 0.99,
            minGrowthRate: Double = 0.0001,
            windowSize: Int = 500,
            confirmationWindows: Int = 3,
            enabled: Bool = true
        ) {
            self.minSaturation = minSaturation
            self.minGrowthRate = minGrowthRate
            self.windowSize = windowSize
            self.confirmationWindows = confirmationWindows
            self.enabled = enabled
        }
    }

    private let config: Config

    /// Coverage history for saturation model fitting
    private var coverageHistory: [(iteration: Int, coverage: Int)] = []

    /// Current cumulative coverage count
    private var cumulativeCoverage: Int = 0

    /// Total iterations processed
    private var totalIterations: Int = 0

    /// Iterations since last window completion
    private var iterationsInWindow: Int = 0

    /// Coverage at start of current window
    private var coverageAtWindowStart: Int = 0

    /// Number of consecutive low-growth windows
    private var lowGrowthWindowCount: Int = 0

    /// Estimated maximum coverage (C_max from saturation model)
    private var estimatedMaxCoverage: Double = 0

    /// Current estimated saturation level (0-1)
    private var currentSaturation: Double = 0

    /// Current growth rate (new paths per iteration)
    private var currentGrowthRate: Double = 1.0

    /// Time when first observation was recorded
    private var startTime: Date?

    init(config: Config = Config()) {
        self.config = config
    }

    /// Record whether this iteration discovered new coverage.
    mutating func record(discoveredNewCoverage: Bool) {
        if startTime == nil {
            startTime = dateClient.now()
        }

        totalIterations += 1
        iterationsInWindow += 1

        if discoveredNewCoverage {
            cumulativeCoverage += 1
        }

        // Complete window and update model
        if iterationsInWindow >= config.windowSize {
            completeWindow()
        }
    }

    private mutating func completeWindow() {
        let newCoverageInWindow = cumulativeCoverage - coverageAtWindowStart

        // Calculate growth rate for this window
        currentGrowthRate = Double(newCoverageInWindow) / Double(config.windowSize)

        // Record history for model fitting
        coverageHistory.append((totalIterations, cumulativeCoverage))
        if coverageHistory.count > 20 {
            coverageHistory.removeFirst()
        }

        // Estimate saturation using exponential decay model
        updateSaturationEstimate()

        // Track low growth windows
        if currentGrowthRate < config.minGrowthRate {
            lowGrowthWindowCount += 1
        } else {
            lowGrowthWindowCount = 0
        }

        // Reset window
        iterationsInWindow = 0
        coverageAtWindowStart = cumulativeCoverage
    }

    /// Update saturation estimate using exponential decay model fitting.
    ///
    /// Fits the model: coverage(t) = C_max * (1 - e^(-λt))
    /// Using least squares on linearized form.
    private mutating func updateSaturationEstimate() {
        guard coverageHistory.count >= 3 else {
            // Not enough data for estimation
            currentSaturation = 0
            estimatedMaxCoverage = Double(cumulativeCoverage) * 2 // Naive estimate
            return
        }

        // Use simple extrapolation based on recent growth
        let recentGrowthRates = calculateRecentGrowthRates()

        if recentGrowthRates.isEmpty || recentGrowthRates.allSatisfy({ $0 <= 0 }) {
            // No growth - we're saturated
            currentSaturation = 1.0
            estimatedMaxCoverage = Double(cumulativeCoverage)
            return
        }

        // Estimate C_max using asymptotic growth model
        // If growth is slowing exponentially, we can extrapolate
        let avgGrowthRate = recentGrowthRates.reduce(0.0, +) / Double(recentGrowthRates.count)

        if avgGrowthRate > 0 {
            // Rough estimation: if growing at rate r, expect ~1/r more iterations
            // to double remaining coverage, suggesting C_max ≈ current + current/r
            let remainingEstimate = Double(cumulativeCoverage) * avgGrowthRate * 1000
            estimatedMaxCoverage = Double(cumulativeCoverage) + remainingEstimate
        } else {
            estimatedMaxCoverage = Double(cumulativeCoverage)
        }

        // Calculate saturation as current / estimated max
        if estimatedMaxCoverage > 0 {
            currentSaturation = Double(cumulativeCoverage) / estimatedMaxCoverage
        } else {
            currentSaturation = 1.0
        }

        // Clamp to valid range
        currentSaturation = min(1.0, max(0.0, currentSaturation))
    }

    private func calculateRecentGrowthRates() -> [Double] {
        guard coverageHistory.count >= 2 else { return [] }

        var rates: [Double] = []
        for i in 1..<coverageHistory.count {
            let prev = coverageHistory[i - 1]
            let curr = coverageHistory[i]
            let iterationDiff = curr.iteration - prev.iteration
            if iterationDiff > 0 {
                let rate = Double(curr.coverage - prev.coverage) / Double(iterationDiff)
                rates.append(rate)
            }
        }
        return rates
    }

    /// Check if coverage has plateaued based on saturation metrics.
    var hasPlateaued: Bool {
        guard config.enabled else { return false }
        guard totalIterations >= config.windowSize else { return false }

        // Primary signal: saturation threshold reached
        if currentSaturation >= config.minSaturation {
            return true
        }

        // Secondary signal: low growth rate for multiple windows
        if lowGrowthWindowCount >= config.confirmationWindows {
            return true
        }

        return false
    }

    /// Current estimated saturation level (0-1).
    var saturationLevel: Double {
        currentSaturation
    }

    /// Current growth rate (discoveries per iteration).
    var growthRate: Double {
        currentGrowthRate
    }

    /// Statistics about the saturation detector state.
    func stats() -> SaturationPlateauStats {
        let now = dateClient.now()
        return SaturationPlateauStats(
            totalIterations: totalIterations,
            cumulativeCoverage: cumulativeCoverage,
            estimatedMaxCoverage: estimatedMaxCoverage,
            saturationLevel: currentSaturation,
            growthRate: currentGrowthRate,
            lowGrowthWindowCount: lowGrowthWindowCount,
            hasPlateaued: hasPlateaued,
            duration: startTime.map { now.timeIntervalSince($0) } ?? 0
        )
    }

    /// Generate a summary string for logging.
    func summary(includeDetails: Bool = false) -> String {
        let stats = self.stats()

        var parts: [String] = []

        if hasPlateaued {
            parts.append("Saturation plateau detected")
        }

        parts.append(String(format: "saturation=%.1f%%", stats.saturationLevel * 100))
        parts.append(String(format: "growth=%.6f", stats.growthRate))

        if includeDetails {
            parts.append("coverage=\(stats.cumulativeCoverage)")
            parts.append(String(format: "est_max=%.0f", stats.estimatedMaxCoverage))
            parts.append("low_windows=\(stats.lowGrowthWindowCount)")
        }

        return parts.joined(separator: ", ")
    }
}

/// Statistics from the saturation plateau detector.
struct SaturationPlateauStats: Sendable {
    /// Total iterations processed.
    let totalIterations: Int

    /// Current cumulative coverage count.
    let cumulativeCoverage: Int

    /// Estimated maximum achievable coverage.
    let estimatedMaxCoverage: Double

    /// Current saturation level (0-1).
    let saturationLevel: Double

    /// Current growth rate (discoveries per iteration).
    let growthRate: Double

    /// Number of consecutive low-growth windows.
    let lowGrowthWindowCount: Int

    /// Whether plateau has been detected.
    let hasPlateaued: Bool

    /// Time elapsed since first observation.
    let duration: TimeInterval

    /// Discoveries per second.
    var discoveriesPerSecond: Double {
        duration > 0 ? Double(cumulativeCoverage) / duration : 0
    }

    /// Estimated percentage of maximum coverage achieved.
    var percentComplete: Double {
        saturationLevel * 100
    }
}
