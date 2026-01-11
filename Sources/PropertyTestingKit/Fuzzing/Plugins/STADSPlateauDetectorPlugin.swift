//
//  STADSPlateauDetectorPlugin.swift
//  PropertyTestingKit
//
//  Event-based stopping condition plugin using Good-Turing estimator (STADS).
//

import Foundation

// MARK: - Event-Based STADS Plugin

/// Event-based stopping condition plugin using STADS Good-Turing estimator.
///
/// Uses statistical principles from species discovery to estimate the
/// probability of finding new coverage. More principled than simple
/// window-based approaches.
///
/// ## Usage
///
/// ```swift
/// try fuzz(plugins: [.stadsDetector()]) { input in ... }
/// ```
///
/// ## Reference
///
/// Böhme, M. (2018). "STADS: Software Testing as Species Discovery"
/// IEEE Transactions on Software Engineering.
public actor EventBasedSTADSPlugin: EventBasedPlugin {
    public let id: String = "stads_detector"

    private var detector: STADSPlateauDetector

    /// Create a STADS plateau detector plugin.
    ///
    /// - Parameter config: Configuration for STADS detection.
    public init(config: STADSPlateauDetector.Config = .init()) {
        self.detector = STADSPlateauDetector(config: config)
    }

    public func handle<each T: Sendable>(event: PluginEvent<repeat each T>) async throws -> [FuzzPluginAction<repeat each T>] {
        switch event {
        case let .iteration(context):
            detector.record(discoveredNewCoverage: context.discoveredNewCoverage)

            if detector.hasPlateaued {
                return [.stop(FuzzPluginAction<repeat each T>.StopAction(reason: .custom("stads_plateau")))]
            }

            return []
        default:
            return []
        }
    }

    /// Get the underlying STADS detection statistics.
    public func stadsStats() -> STADSPlateauStats {
        detector.stats()
    }
}

// MARK: - Convenience Constructor

extension EventBasedPlugin where Self == EventBasedSTADSPlugin {
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
    ) -> EventBasedSTADSPlugin {
        EventBasedSTADSPlugin(
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
    ) -> EventBasedSTADSPlugin {
        EventBasedSTADSPlugin(config: config)
    }
}
