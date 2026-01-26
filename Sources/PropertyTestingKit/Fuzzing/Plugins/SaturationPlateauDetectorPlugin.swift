//
//  SaturationPlateauDetectorPlugin.swift
//  PropertyTestingKit
//
//  Stopping condition plugin using saturation-based metrics (Green Fuzzing).
//

import Foundation

// MARK: - Saturation Plugin

/// Stopping condition plugin using saturation-based metrics.
///
/// Models coverage growth as an asymptotic process and stops when saturation
/// approaches the estimated maximum coverage.
///
/// ## Usage
///
/// ```swift
/// try fuzz(plugins: [.saturationDetector()]) { input in ... }
/// ```
///
/// ## Reference
///
/// Böhme, M. et al. (2023). "Green Fuzzing: A Saturation-Based Stopping Criterion
/// using a Probabilistic Model to Predict Fuzzing Progress"
/// ISSTA 2023.
public actor SaturationPlugin: FuzzPlugin {
    public let id: String = "saturation_detector"

    private var detector: SaturationPlateauDetector

    /// Create a saturation plateau detector plugin.
    ///
    /// - Parameter config: Configuration for saturation detection.
    public init(config: SaturationPlateauDetector.Config = .init()) {
        self.detector = SaturationPlateauDetector(config: config)
    }

    public func handle<each T: Sendable>(event: consuming PluginEvent<repeat each T>) async throws -> [FuzzPluginAction<repeat each T>] {
        switch event {
        case let .iteration(context):
            detector.record(discoveredNewCoverage: context.discoveredNewCoverage)

            if detector.hasPlateaued {
                return [.stop(FuzzPluginAction<repeat each T>.StopAction(reason: .custom("saturation_plateau")))]
            }

            return []
        default:
            return []
        }
    }

    /// Get the underlying saturation detection statistics.
    public func saturationStats() -> SaturationPlateauStats {
        detector.stats()
    }
}

// MARK: - Convenience Constructor

extension FuzzPlugin where Self == SaturationPlugin {
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
    ) -> SaturationPlugin {
        SaturationPlugin(
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
    ) -> SaturationPlugin {
        SaturationPlugin(config: config)
    }
}
