//
//  EventBasedPlateauDetectorPlugin.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Foundation

public actor EventBasedPlateauDetectorPlugin: EventBasedPlugin {
    public let id: String = "plateau_detector" 

    private var detector: SimpleCoveragePlateauDetector

    /// Create a plateau detector plugin.
    ///
    /// - Parameters:
    ///   - config: Configuration for plateau detection.
    public init(config: SimpleCoveragePlateauDetector.Config = .init()) {
        self.detector = SimpleCoveragePlateauDetector(config: config)
    }

    public func handle<each T: Sendable>(event: PluginEvent<repeat each T>) async throws -> [FuzzPluginAction<repeat each T>] {
        switch event {
        case let .iteration(context):
            detector.record(discoveredNewCoverage: context.discoveredNewCoverage)

            if detector.hasPlateaued {
                return [.stop(FuzzPluginAction<repeat each T>.StopAction(reason: "coverage_plateau"))]
            }

            return []
        default:
            return []
        }
    }
}
