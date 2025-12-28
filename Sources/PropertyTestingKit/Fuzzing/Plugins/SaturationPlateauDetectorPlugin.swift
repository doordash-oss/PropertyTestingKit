//
//  SaturationPlateauDetectorPlugin.swift
//  PropertyTestingKit
//
//  Stopping condition plugin using saturation-based metrics (Green Fuzzing).
//

import Foundation

/// Stopping condition plugin using saturation-based metrics (Green Fuzzing, ISSTA 2023).
///
/// Models coverage growth as an asymptotic process and stops when saturation
/// approaches the estimated maximum coverage.
///
/// ## Usage
///
/// ```swift
/// try fuzz(stoppingPlugins: [.saturationDetector()]) { input in ... }
/// ```
///
/// ## Reference
///
/// Böhme, M. et al. (2023). "Green Fuzzing: A Saturation-Based Stopping Criterion
/// using a Probabilistic Model to Predict Fuzzing Progress"
/// ISSTA 2023.
///
/// For simpler approaches, see ``PlateauDetectorPlugin``.
/// For Good-Turing estimator, see ``STADSPlateauDetectorPlugin``.
public struct SaturationPlateauDetectorPlugin: StoppingConditionPlugin, @unchecked Sendable {
    public let id: String = "saturationDetector"
    public let priority: Int

    private var detector: SaturationPlateauDetector

    /// Create a saturation plateau detector plugin.
    ///
    /// - Parameters:
    ///   - config: Configuration for saturation detection.
    ///   - priority: Plugin priority (higher runs first). Default is 100.
    public init(
        config: SaturationPlateauDetector.Config = .init(),
        priority: Int = 100
    ) {
        self.detector = SaturationPlateauDetector(config: config)
        self.priority = priority
    }

    public mutating func recordIteration(discoveredNewCoverage: Bool) {
        detector.record(discoveredNewCoverage: discoveredNewCoverage)
    }

    public func shouldStop(context: FuzzPluginContext.StoppingContext) -> StoppingDecision {
        if detector.hasPlateaued {
            return .stop(reason: "saturation_plateau")
        }
        return .continue
    }

    public func stats() -> StoppingConditionStats {
        let satStats = detector.stats()
        return StoppingConditionStats(
            pluginId: id,
            hasTriggered: detector.hasPlateaued,
            details: [
                "saturationLevel": String(format: "%.4f", satStats.saturationLevel),
                "growthRate": String(format: "%.6f", satStats.growthRate),
                "cumulativeCoverage": String(satStats.cumulativeCoverage),
                "estimatedMaxCoverage": String(format: "%.0f", satStats.estimatedMaxCoverage),
                "lowGrowthWindowCount": String(satStats.lowGrowthWindowCount)
            ]
        )
    }

    /// Get the underlying saturation detection statistics.
    public func saturationStats() -> SaturationPlateauStats {
        detector.stats()
    }
}

// MARK: - Convenience Constructor

extension StoppingConditionPlugin where Self == SaturationPlateauDetectorPlugin {
    /// Create a saturation plateau detector stopping condition plugin.
    ///
    /// Uses saturation-based metrics to model coverage growth and
    /// detect when continued fuzzing will yield diminishing returns.
    ///
    /// - Parameters:
    ///   - minSaturation: Saturation level (0-1) to declare plateau. Default is 0.99.
    ///   - minGrowthRate: Minimum growth rate before plateau. Default is 0.0001.
    ///   - windowSize: Window size for growth rate calculation. Default is 500.
    ///   - confirmationWindows: Consecutive low-growth windows required. Default is 3.
    /// - Returns: A configured saturation plateau detector plugin.
    public static func saturationDetector(
        minSaturation: Double = 0.99,
        minGrowthRate: Double = 0.0001,
        windowSize: Int = 500,
        confirmationWindows: Int = 3
    ) -> SaturationPlateauDetectorPlugin {
        SaturationPlateauDetectorPlugin(
            config: .init(
                minSaturation: minSaturation,
                minGrowthRate: minGrowthRate,
                windowSize: windowSize,
                confirmationWindows: confirmationWindows
            )
        )
    }

    /// Create a saturation plateau detector plugin with custom configuration.
    ///
    /// - Parameter config: The saturation detector configuration.
    /// - Returns: A configured saturation plateau detector plugin.
    public static func saturationDetector(
        config: SaturationPlateauDetector.Config
    ) -> SaturationPlateauDetectorPlugin {
        SaturationPlateauDetectorPlugin(config: config)
    }
}
