//
//  PlateauDetectorPlugin.swift
//  PropertyTestingKit
//
//  Stopping condition plugin that detects coverage plateaus.
//

import Foundation

/// Stopping condition plugin that stops fuzzing when coverage plateaus.
///
/// This plugin wraps ``SimpleCoveragePlateauDetector`` to provide early stopping
/// when the fuzzer stops discovering new coverage paths. Uses a simple sliding
/// window heuristic to detect when discovery rate drops.
///
/// For more sophisticated stopping criteria, see:
/// - ``STADSPlateauDetectorPlugin`` - Good-Turing estimator (Böhme 2018)
/// - ``SaturationPlateauDetectorPlugin`` - Saturation-based metrics (Green Fuzzing, ISSTA 2023)
///
/// Usage:
/// ```swift
/// try fuzz(stoppingPlugins: [.plateauDetector()]) { input in ... }
/// ```
public struct PlateauDetectorPlugin: StoppingConditionPlugin, @unchecked Sendable {
    public let id: String = "plateauDetector"
    public let priority: Int

    private var detector: SimpleCoveragePlateauDetector

    /// Create a plateau detector plugin.
    ///
    /// - Parameters:
    ///   - config: Configuration for plateau detection.
    ///   - priority: Plugin priority (higher runs first). Default is 100.
    public init(
        config: SimpleCoveragePlateauDetector.Config = .init(),
        priority: Int = 100
    ) {
        self.detector = SimpleCoveragePlateauDetector(config: config)
        self.priority = priority
    }

    public mutating func recordIteration(discoveredNewCoverage: Bool) {
        detector.record(discoveredNewCoverage: discoveredNewCoverage)
    }

    public func shouldStop(context: FuzzPluginContext.StoppingContext) -> StoppingDecision {
        if detector.hasPlateaued {
            return .stop(reason: "coverage_plateau")
        }
        return .continue
    }

    public func stats() -> StoppingConditionStats {
        let plateauStats = detector.stats()
        return StoppingConditionStats(
            pluginId: id,
            hasTriggered: detector.hasPlateaued,
            details: [
                "windowRate": String(format: "%.4f", plateauStats.windowRate),
                "overallRate": String(format: "%.4f", plateauStats.overallRate),
                "rateEMA": String(format: "%.4f", plateauStats.rateEMA),
                "lowRateWindowCount": String(plateauStats.lowRateWindowCount),
                "totalDiscoveries": String(plateauStats.totalDiscoveries)
            ]
        )
    }

    /// Get the underlying plateau detection statistics.
    /// Use this for detailed plateau analysis.
    public func plateauStats() -> PlateauStats {
        detector.stats()
    }
}

// MARK: - Convenience Constructor

extension StoppingConditionPlugin where Self == PlateauDetectorPlugin {
    /// Create a plateau detector stopping condition plugin.
    ///
    /// - Parameters:
    ///   - windowSize: Size of sliding window for rate calculation. Default is 500.
    ///   - minDiscoveryRate: Minimum discovery rate before declaring plateau. Default is 0.001.
    ///   - confirmationWindows: Number of consecutive low-rate windows required. Default is 3.
    /// - Returns: A configured plateau detector plugin.
    public static func plateauDetector(
        windowSize: Int = 500,
        minDiscoveryRate: Double = 0.001,
        confirmationWindows: Int = 3
    ) -> PlateauDetectorPlugin {
        PlateauDetectorPlugin(
            config: .init(
                windowSize: windowSize,
                minDiscoveryRate: minDiscoveryRate,
                confirmationWindows: confirmationWindows
            )
        )
    }

    /// Create a plateau detector plugin with custom configuration.
    ///
    /// - Parameter config: The plateau detector configuration.
    /// - Returns: A configured plateau detector plugin.
    public static func plateauDetector(
        config: SimpleCoveragePlateauDetector.Config
    ) -> PlateauDetectorPlugin {
        PlateauDetectorPlugin(config: config)
    }
}
