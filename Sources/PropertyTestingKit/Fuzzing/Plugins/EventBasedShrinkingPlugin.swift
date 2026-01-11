//
//  EventBasedShrinkingPlugin.swift
//  PropertyTestingKit
//
//  Event-based shrinking plugin for minimizing failing inputs.
//

import Foundation
import Testing

// MARK: - Event-Based Shrinking Plugin

/// Shrinking plugin that minimizes failing inputs using delta debugging.
///
/// When a test failure is found, this plugin attempts to find a smaller
/// input that still reproduces the failure, making debugging easier.
///
/// ## Usage
///
/// ```swift
/// try fuzz(plugins: [.shrinking()]) { input in
///     // Your test here
/// }
/// ```
public struct EventBasedShrinkingPlugin: EventBasedPlugin {
    public let id: String = "shrinking"

    public let config: ShrinkConfig

    /// Whether to print verbose progress during shrinking.
    public let verbose: Bool

    /// Create a shrinking plugin.
    ///
    /// - Parameters:
    ///   - config: Shrinking configuration.
    ///   - verbose: Whether to print verbose progress. Defaults to false.
    public init(
        config: ShrinkConfig = ShrinkConfig(),
        verbose: Bool = false
    ) {
        self.config = config
        self.verbose = verbose
    }

    public func handle<each T: Sendable>(event: PluginEvent<repeat each T>) async throws -> [FuzzPluginAction<repeat each T>] {
        switch event {
        case let .failureFound(context):
            let shrinker = MultiComponentShrinker(config: config)
            let (minimized, stats) = await shrinker.shrink(input: context.input, test: context.test)

            // Format minimized input for display
            let minimizedDescription = formatMinimizedInput(minimized)

            // Build shrink result message
            var message = "[Shrink] Minimized failing input"
            message += "\n  Original size: \(stats.originalSize) elements"
            message += "\n  Minimized size: \(stats.minimizedSize) elements"
            message += "\n  Candidates tested: \(stats.candidatesTested)"

            if stats.minimizedSize < stats.originalSize {
                let reduction = Double(stats.originalSize - stats.minimizedSize) / Double(stats.originalSize) * 100
                message += "\n  Reduction: \(String(format: "%.1f", reduction))%"
            }

            message += "\n  Minimized input: \(minimizedDescription)"

            if verbose {
                print(message)
            }

            // Return actions: select for mutation, add to corpus, and record issue
            return [
                .selectForMutation(.init(input: minimized)),
                .submitToCorpus(.init(input: minimized)),
                .recordIssue(.init(
                    comment: Comment(rawValue: message),
                    sourceLocation: context.sourceLocation
                ))
            ]
        default:
            return []
        }
    }

    /// Format minimized input for display.
    private func formatMinimizedInput<each T>(_ input: (repeat each T)) -> String {
        // Use Mirror to get a readable representation
        let mirror = Mirror(reflecting: input)
        if mirror.children.isEmpty {
            return String(describing: input)
        }

        // For tuples, format each element
        var elements: [String] = []
        for child in mirror.children {
            elements.append(String(describing: child.value))
        }
        return "(\(elements.joined(separator: ", ")))"
    }
}

// MARK: - Convenience Factory

extension EventBasedPlugin where Self == EventBasedShrinkingPlugin {
    /// Create a shrinking plugin that minimizes failing inputs.
    ///
    /// - Parameters:
    ///   - config: Shrinking configuration.
    ///   - verbose: Whether to print verbose progress.
    /// - Returns: A configured shrinking plugin.
    public static func shrinking(
        config: ShrinkConfig = ShrinkConfig(),
        verbose: Bool = false
    ) -> EventBasedShrinkingPlugin {
        EventBasedShrinkingPlugin(config: config, verbose: verbose)
    }
}
