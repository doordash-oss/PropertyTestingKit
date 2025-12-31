//
//  DefaultShrinkingPlugin.swift
//  PropertyTestingKit
//
//  Default implementation of ShrinkingPlugin.
//

import Foundation

// MARK: - Default Shrinking Plugin

/// Default shrinking plugin that uses delta debugging to minimize failing inputs.
///
/// This plugin wraps `TestCaseShrinker` and provides reasonable defaults for
/// most use cases.
public struct DefaultShrinkingPlugin: ShrinkingPlugin {
    public let id: String
    public let priority: Int
    public let config: ShrinkConfig
    public let isEnabled: Bool

    /// Whether to print verbose progress during shrinking.
    public let verbose: Bool

    /// Create a default shrinking plugin.
    ///
    /// - Parameters:
    ///   - id: Plugin identifier. Defaults to "shrinking".
    ///   - priority: Plugin priority. Defaults to 0.
    ///   - config: Shrinking configuration.
    ///   - enabled: Whether shrinking is enabled. Defaults to true.
    ///   - verbose: Whether to print verbose progress. Defaults to false.
    public init(
        id: String = "shrinking",
        priority: Int = 0,
        config: ShrinkConfig = ShrinkConfig(),
        enabled: Bool = true,
        verbose: Bool = false
    ) {
        self.id = id
        self.priority = priority
        self.config = config
        self.isEnabled = enabled
        self.verbose = verbose
    }

    public func onShrinkingStart(originalSize: Int, error: Error) async {
        if verbose {
            print("[Shrink] Starting shrinking for input of size \(originalSize)")
            print("[Shrink] Error: \(error)")
        }
    }

    public func onShrinkingProgress(candidatesTested: Int, currentSize: Int, originalSize: Int) async {
        if verbose {
            let reduction = originalSize > 0
                ? String(format: "%.1f%%", (1.0 - Double(currentSize) / Double(originalSize)) * 100)
                : "0%"
            print("[Shrink] Progress: \(candidatesTested) candidates tested, size \(currentSize) (\(reduction) reduction)")
        }
    }

    public func onShrinkingComplete(stats: ShrinkStats) async {
        if verbose {
            print(stats.report())
        }
    }
}

// MARK: - Convenience Factory

extension ShrinkingPlugin where Self == DefaultShrinkingPlugin {
    /// Create a default shrinking plugin.
    ///
    /// - Parameters:
    ///   - config: Shrinking configuration.
    ///   - verbose: Whether to print verbose progress.
    /// - Returns: A configured shrinking plugin.
    public static func `default`(
        config: ShrinkConfig = ShrinkConfig(),
        verbose: Bool = false
    ) -> DefaultShrinkingPlugin {
        DefaultShrinkingPlugin(config: config, verbose: verbose)
    }

    /// Create a disabled shrinking plugin (no-op).
    public static var disabled: DefaultShrinkingPlugin {
        DefaultShrinkingPlugin(enabled: false)
    }
}

struct EventBasedShrinkingPlugin: EventBasedPlugin {
    public let config: ShrinkConfig

    /// Whether to print verbose progress during shrinking.
    public let verbose: Bool

    /// Create a default shrinking plugin.
    ///
    /// - Parameters:
    ///   - id: Plugin identifier. Defaults to "shrinking".
    ///   - priority: Plugin priority. Defaults to 0.
    ///   - config: Shrinking configuration.
    ///   - enabled: Whether shrinking is enabled. Defaults to true.
    ///   - verbose: Whether to print verbose progress. Defaults to false.
    public init(
        config: ShrinkConfig = ShrinkConfig(),
        verbose: Bool = false
    ) {
        self.config = config
        self.verbose = verbose
    }

    mutating func handle<each T: Sendable>(event: PluginEvent<repeat each T>) async throws -> [FuzzPluginAction] {
        switch event {
        case let .failureFound(context):
            let shrinker = MultiComponentShrinker(config: config)
            let (minimized, _) = await shrinker.shrink(input: context.input, test: context.test)
            return []
        default: return []
        }
    }
}
