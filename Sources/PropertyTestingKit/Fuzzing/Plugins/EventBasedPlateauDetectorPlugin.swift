//
//  EventBasedPlateauDetectorPlugin.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Foundation

struct EventBasedPlateauDetectorPlugin: EventBasedPlugin {
    var detector: SimpleCoveragePlateauDetector

    /// Create a plateau detector plugin.
    ///
    /// - Parameters:
    ///   - config: Configuration for plateau detection.
    public init(config: SimpleCoveragePlateauDetector.Config = .init()) {
        self.detector = SimpleCoveragePlateauDetector(config: config)
    }

    mutating func handle<each T>(event: PluginEvent<repeat each T>) async throws -> [FuzzPluginAction] {
        switch event {
        case let .iteration(context):
            detector.record(discoveredNewCoverage: context.discoveredNewCoverage)

            if detector.hasPlateaued {
                return [.stop(.init(reason: "coverage_plateau"))]
            }

            return []
        default: return []
        }
    }
}
