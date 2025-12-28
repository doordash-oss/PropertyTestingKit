//
//  STADSPlateauDetectorPlugin.swift
//  PropertyTestingKit
//
//  Stopping condition plugin using Good-Turing estimator (STADS).
//

import Foundation

/// Stopping condition plugin using STADS Good-Turing estimator (Böhme 2018).
///
/// Uses statistical principles from species discovery to estimate the
/// probability of finding new coverage. More principled than simple
/// window-based approaches.
///
/// ## Usage
///
/// ```swift
/// try fuzz(stoppingPlugins: [.stadsDetector()]) { input in ... }
/// ```
///
/// ## Reference
///
/// Böhme, M. (2018). "STADS: Software Testing as Species Discovery"
/// IEEE Transactions on Software Engineering.
///
/// For simpler approaches, see ``PlateauDetectorPlugin``.
/// For saturation-based metrics, see ``SaturationPlateauDetectorPlugin``.
public struct STADSPlateauDetectorPlugin: StoppingConditionPlugin, @unchecked Sendable {
    public let id: String = "stadsDetector"
    public let priority: Int

    private var detector: STADSPlateauDetector

    /// Create a STADS plateau detector plugin.
    ///
    /// - Parameters:
    ///   - config: Configuration for STADS detection.
    ///   - priority: Plugin priority (higher runs first). Default is 100.
    public init(
        config: STADSPlateauDetector.Config = .init(),
        priority: Int = 100
    ) {
        self.detector = STADSPlateauDetector(config: config)
        self.priority = priority
    }

    public mutating func recordIteration(discoveredNewCoverage: Bool) {
        detector.record(discoveredNewCoverage: discoveredNewCoverage)
    }

    public func shouldStop(context: FuzzPluginContext.StoppingContext) -> StoppingDecision {
        if detector.hasPlateaued {
            return .stop(reason: "stads_plateau")
        }
        return .continue
    }

    public func stats() -> StoppingConditionStats {
        let stadsStats = detector.stats()
        return StoppingConditionStats(
            pluginId: id,
            hasTriggered: detector.hasPlateaued,
            details: [
                "discoveryProbability": String(format: "%.6f", stadsStats.discoveryProbability),
                "singletonCount": String(stadsStats.singletonCount),
                "totalDiscoveries": String(stadsStats.totalDiscoveries),
                "lowProbabilityChecks": String(stadsStats.lowProbabilityChecks)
            ]
        )
    }

    /// Get the underlying STADS detection statistics.
    public func stadsStats() -> STADSPlateauStats {
        detector.stats()
    }
}

// MARK: - Convenience Constructor

extension StoppingConditionPlugin where Self == STADSPlateauDetectorPlugin {
    /// Create a STADS plateau detector stopping condition plugin.
    ///
    /// Uses the Good-Turing estimator to estimate the probability of
    /// discovering new coverage paths.
    ///
    /// - Parameters:
    ///   - minDiscoveryProbability: Minimum probability before declaring plateau. Default is 0.001.
    ///   - confirmationChecks: Consecutive low-probability checks required. Default is 3.
    ///   - checkInterval: Iterations between probability recalculations. Default is 100.
    /// - Returns: A configured STADS plateau detector plugin.
    public static func stadsDetector(
        minDiscoveryProbability: Double = 0.001,
        confirmationChecks: Int = 3,
        checkInterval: Int = 100
    ) -> STADSPlateauDetectorPlugin {
        STADSPlateauDetectorPlugin(
            config: .init(
                minDiscoveryProbability: minDiscoveryProbability,
                confirmationChecks: confirmationChecks,
                checkInterval: checkInterval
            )
        )
    }

    /// Create a STADS plateau detector plugin with custom configuration.
    ///
    /// - Parameter config: The STADS detector configuration.
    /// - Returns: A configured STADS plateau detector plugin.
    public static func stadsDetector(
        config: STADSPlateauDetector.Config
    ) -> STADSPlateauDetectorPlugin {
        STADSPlateauDetectorPlugin(config: config)
    }
}
