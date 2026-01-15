//
//  PluginDispatcher.swift
//  PropertyTestingKit
//
//  Dispatches events to plugins and collects actions.
//

import Foundation

/// Dispatches plugin events to all registered plugins and collects their actions.
public struct PluginDispatcher: Sendable {
    private var plugins: [any FuzzPlugin]

    /// Create a dispatcher with the given plugins.
    ///
    /// Plugins are called in array order for each event.
    ///
    /// - Parameter plugins: The plugins to dispatch events to.
    public init(plugins: [any FuzzPlugin]) {
        self.plugins = plugins
    }

    /// Dispatch an event to all plugins and collect their actions.
    ///
    /// - Parameter event: The event to dispatch.
    /// - Returns: All actions returned by all plugins, in order.
    public func dispatch<each T: Sendable>(
        event: PluginEvent<repeat each T>
    ) async throws -> [FuzzPluginAction<repeat each T>] {
        var results = [FuzzPluginAction<repeat each T>]()
        for plugin in plugins {
            try await results.append(contentsOf: plugin.handle(event: event))
        }
        return results
    }
}
