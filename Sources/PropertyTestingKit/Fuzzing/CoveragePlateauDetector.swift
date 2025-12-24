//
//  CoveragePlateauDetector.swift
//  PropertyTestingKit
//
//  Adaptive early stopping based on coverage discovery rate.
//
//  Based on insights from:
//  - Böhme (2020) - Entropic: Information-theoretic perspective on fuzzer efficiency
//  - Elhage (2020) - Property Testing Like AFL: Stop when coverage plateaus
//

import Foundation
import Dependencies

/// Detects when fuzzing has reached a coverage plateau and should stop early.
///
/// Instead of simply counting iterations without new coverage, this detector
/// tracks the actual discovery rate over a sliding window and uses statistical
/// analysis to detect when the rate has dropped below a threshold.
///
/// ## Algorithm
///
/// 1. Track coverage discoveries in a sliding window
/// 2. Compute discovery rate as (discoveries / window_size)
/// 3. Track rate trend over time (exponential moving average)
/// 4. Detect plateau when:
///    - Rate falls below minimum threshold
///    - Rate trend shows sustained decline
///    - Confidence in plateau is high enough
///
/// ## Reference
///
/// This approach is inspired by entropic fuzzing (Böhme 2020) which uses
/// information-theoretic principles to measure fuzzing progress.
public struct CoveragePlateauDetector: Sendable {
    @Dependency(\.dateClient) var dateClient

    /// Configuration for plateau detection.
    public struct Config: Sendable {
        /// Size of sliding window for rate calculation.
        public var windowSize: Int

        /// Minimum discovery rate before declaring plateau (discoveries per iteration).
        /// Default: 0.001 = 1 discovery per 1000 iterations
        public var minDiscoveryRate: Double

        /// Number of consecutive low-rate windows required to confirm plateau.
        /// Higher values prevent false positives but delay detection.
        public var confirmationWindows: Int

        /// Whether plateau detection is enabled.
        /// When disabled, the detector never reports plateau.
        public var enabled: Bool

        public init(
            windowSize: Int = 500,
            minDiscoveryRate: Double = 0.001,
            confirmationWindows: Int = 3,
            enabled: Bool = true
        ) {
            self.windowSize = windowSize
            self.minDiscoveryRate = minDiscoveryRate
            self.confirmationWindows = confirmationWindows
            self.enabled = enabled
        }
    }

    private let config: Config

    /// Actual window size used (guaranteed to be at least 1).
    private let effectiveWindowSize: Int

    /// Ring buffer tracking whether each iteration discovered new coverage.
    private var discoveryWindow: [Bool]

    /// Current position in the ring buffer.
    private var windowIndex: Int = 0

    /// Number of items in the window (may be less than window size initially).
    private var windowCount: Int = 0

    /// Count of discoveries in the current window.
    private var discoveriesInWindow: Int = 0

    /// Number of consecutive windows with low discovery rate.
    private var lowRateWindowCount: Int = 0

    /// Total discoveries since start (for statistics).
    private var totalDiscoveries: Int = 0

    /// Total iterations since start (for statistics).
    private var totalIterations: Int = 0

    /// Time when first iteration was recorded.
    private var startTime: Date?

    /// Discovery rates for trend analysis.
    private var rateHistory: [Double] = []

    /// Exponential moving average of discovery rate.
    private var rateEMA: Double = 1.0

    /// EMA smoothing factor (lower = more smoothing).
    private let emaSmoothingFactor: Double = 0.1

    public init(config: Config = Config()) {
        self.config = config
        // Ensure windowSize is at least 1 to prevent empty array access
        self.effectiveWindowSize = max(1, config.windowSize)
        self.discoveryWindow = Array(repeating: false, count: effectiveWindowSize)
    }

    /// Record an iteration and whether it discovered new coverage.
    ///
    /// - Parameter discoveredNewCoverage: true if this iteration found new paths.
    public mutating func record(discoveredNewCoverage: Bool) async {
        if startTime == nil {
            startTime = await dateClient.now()
        }

        // Update ring buffer
        let oldValue = discoveryWindow[windowIndex]
        if oldValue && windowCount == effectiveWindowSize {
            discoveriesInWindow -= 1
        }

        discoveryWindow[windowIndex] = discoveredNewCoverage
        if discoveredNewCoverage {
            discoveriesInWindow += 1
            totalDiscoveries += 1
        }

        windowIndex = (windowIndex + 1) % effectiveWindowSize
        windowCount = min(windowCount + 1, effectiveWindowSize)
        totalIterations += 1

        // Update rate tracking when window is full
        if windowCount >= effectiveWindowSize {
            let currentRate = Double(discoveriesInWindow) / Double(windowCount)

            // Update rate history
            rateHistory.append(currentRate)
            if rateHistory.count > 10 {
                rateHistory.removeFirst()
            }

            // Update EMA
            rateEMA = rateEMA * (1 - emaSmoothingFactor) + currentRate * emaSmoothingFactor

            // Track low rate windows
            if currentRate < config.minDiscoveryRate {
                lowRateWindowCount += 1
            } else {
                lowRateWindowCount = 0
            }
        }
    }

    /// Check if coverage has plateaued.
    ///
    /// - Returns: true if fuzzing should stop due to plateau.
    public var hasPlateaued: Bool {
        guard config.enabled else { return false }
        guard windowCount >= effectiveWindowSize else { return false }

        // Primary signal: consecutive low-rate windows
        if lowRateWindowCount >= config.confirmationWindows {
            return true
        }

        // Secondary signal: rate trend is declining toward zero
        if rateHistory.count >= 5 {
            let recentRates = Array(rateHistory.suffix(5))
            let isConsistentlyLow = recentRates.allSatisfy { $0 < config.minDiscoveryRate * 2 }
            let isTrendingDown = recentRates.last ?? 0 < recentRates.first ?? 1

            if isConsistentlyLow && isTrendingDown && rateEMA < config.minDiscoveryRate {
                return true
            }
        }

        return false
    }

    /// Current discovery rate (discoveries per iteration).
    public var currentRate: Double {
        guard windowCount > 0 else { return 0 }
        return Double(discoveriesInWindow) / Double(windowCount)
    }

    /// Overall discovery rate since start.
    public var overallRate: Double {
        guard totalIterations > 0 else { return 0 }
        return Double(totalDiscoveries) / Double(totalIterations)
    }

    /// Statistics about the plateau detector state.
    public func stats() async -> PlateauStats {
        let now = await dateClient.now()
        return PlateauStats(
            totalIterations: totalIterations,
            totalDiscoveries: totalDiscoveries,
            windowRate: currentRate,
            overallRate: overallRate,
            rateEMA: rateEMA,
            lowRateWindowCount: lowRateWindowCount,
            hasPlateaued: hasPlateaued,
            duration: startTime.map { now.timeIntervalSince($0) } ?? 0
        )
    }

    /// Generate a summary string for logging.
    public func summary(includeDetails: Bool = false) async -> String {
        let stats = await self.stats()

        var parts: [String] = []

        if hasPlateaued {
            parts.append("Coverage plateau detected")
        }

        parts.append(String(format: "rate=%.4f", stats.windowRate))
        parts.append("discoveries=\(stats.totalDiscoveries)")

        if includeDetails {
            parts.append(String(format: "ema=%.4f", stats.rateEMA))
            parts.append("low_windows=\(stats.lowRateWindowCount)")
        }

        return parts.joined(separator: ", ")
    }
}

/// Statistics from the plateau detector.
public struct PlateauStats: Sendable {
    /// Total iterations processed.
    public let totalIterations: Int

    /// Total coverage discoveries.
    public let totalDiscoveries: Int

    /// Discovery rate in current window.
    public let windowRate: Double

    /// Overall discovery rate since start.
    public let overallRate: Double

    /// Exponential moving average of discovery rate.
    public let rateEMA: Double

    /// Number of consecutive windows with low discovery rate.
    public let lowRateWindowCount: Int

    /// Whether plateau has been detected.
    public let hasPlateaued: Bool

    /// Time elapsed since first iteration.
    public let duration: TimeInterval

    /// Discoveries per second.
    public var discoveriesPerSecond: Double {
        duration > 0 ? Double(totalDiscoveries) / duration : 0
    }
}
