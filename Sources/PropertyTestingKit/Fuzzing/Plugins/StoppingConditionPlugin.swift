//
//  StoppingConditionPlugin.swift
//  PropertyTestingKit
//
//  Plugins that influence when fuzzing should stop.
//

import Foundation

// MARK: - Stopping Decision

/// Decision returned by stopping condition plugins.
public enum StoppingDecision: Sendable {
    /// Continue fuzzing.
    case `continue`

    /// Stop fuzzing with the given reason.
    case stop(reason: String)
}

// MARK: - Stopping Condition Plugin Protocol

/// Plugin protocol for custom stopping conditions.
/// These plugins are consulted after each batch to determine if fuzzing should stop.
public protocol StoppingConditionPlugin: FuzzPlugin {
    /// Record that an iteration occurred with the given coverage discovery status.
    /// Called for each iteration to allow the plugin to track state.
    ///
    /// - Parameter discoveredNewCoverage: Whether this iteration found new coverage paths.
    mutating func recordIteration(discoveredNewCoverage: Bool)

    /// Check if fuzzing should stop.
    ///
    /// - Parameter context: Current fuzzing state information.
    /// - Returns: Decision to continue or stop.
    func shouldStop(context: FuzzPluginContext.StoppingContext) -> StoppingDecision

    /// Statistics from this stopping condition plugin.
    func stats() -> StoppingConditionStats
}

// MARK: - Stopping Condition Stats

/// Statistics from a stopping condition plugin.
public struct StoppingConditionStats: Sendable {
    /// Plugin identifier.
    public let pluginId: String

    /// Whether the plugin has triggered a stop.
    public let hasTriggered: Bool

    /// Additional plugin-specific information.
    public let details: [String: String]

    public init(
        pluginId: String,
        hasTriggered: Bool,
        details: [String: String] = [:]
    ) {
        self.pluginId = pluginId
        self.hasTriggered = hasTriggered
        self.details = details
    }
}
