//
//  PlateauDetectorPlugin.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Foundation

public struct PlateauDetectorPlugin: FuzzPlugin {
    public let id: String = "plateau_detector"

    private let detector: Box<SimpleCoveragePlateauDetector>

    /// Create a plateau detector plugin.
    ///
    /// - Parameters:
    ///   - config: Configuration for plateau detection.
    public init(config: SimpleCoveragePlateauDetector.Config = .init()) {
        self.detector = Box(SimpleCoveragePlateauDetector(config: config))
    }

    public func handle<each T: Sendable>(event: SyncPluginEvent<repeat each T>) -> [FuzzPluginAction<repeat each T>] {
        switch event {
        case let .iteration(context):
            detector.value.record(discoveredNewCoverage: context.discoveredNewCoverage)

            if detector.value.hasPlateaued {
                return [.stop(FuzzPluginAction<repeat each T>.StopAction(reason: .custom("coverage_plateaued")))]
            }

            return []
        }
    }
}

/// Simple box for reference semantics. Not thread-safe.
/// Plugins run on a single task so no synchronization needed.
@usableFromInline
final class Box<Value>: @unchecked Sendable {
    @usableFromInline
    var value: Value

    @usableFromInline
    init(_ value: Value) {
        self.value = value
    }
}
