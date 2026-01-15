//
//  MutationPlugin.swift
//  PropertyTestingKit
//
//  Plugin that triggers mutations when new coverage is discovered.
//

/// A plugin that selects inputs for mutation when they discover new coverage.
///
/// This is a baseline plugin that implements the core fuzzing feedback loop:
/// when an input discovers new coverage, it should be mutated to explore
/// similar inputs that might discover additional coverage.
public struct MutationPlugin: FuzzPlugin {
    public let id: String = "mutation"

    public init() {}

    public func handle<each T: Sendable>(
        event: PluginEvent<repeat each T>
    ) async throws -> [FuzzPluginAction<repeat each T>] {
        switch event {
        case let .iteration(context):
            if context.discoveredNewCoverage {
                return [.selectForMutation(.init(input: context.input))]
            }
            return []

        case .start, .end, .failureFound:
            return []
        }
    }
}
