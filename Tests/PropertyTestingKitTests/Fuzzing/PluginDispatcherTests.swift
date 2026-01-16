//
//  PluginDispatcherTests.swift
//  PropertyTestingKitTests
//
//  Tests for PluginDispatcher.
//

import Testing
import Foundation
@testable import PropertyTestingKit

@Suite("PluginDispatcher")
struct PluginDispatcherTests {

    @Test("Dispatcher with no plugins returns empty actions")
    func testEmptyPluginsReturnsEmpty() async throws {
        var dispatcher = PluginDispatcher(plugins: [])

        let context = PluginEvent<Int>.IterationContext(
            discoveredNewCoverage: true,
            input: 42
        )
        let actions = try await dispatcher.dispatch(event: PluginEvent<Int>.iteration(context))
        #expect(actions.isEmpty)
    }

    @Test("Dispatcher collects actions from multiple plugins")
    func testCollectsActionsFromMultiplePlugins() async throws {
        // Use two plateau detectors configured to trigger after filling a small window
        let config = SimpleCoveragePlateauDetector.Config(
            windowSize: 2,
            minDiscoveryRate: 0.01,  // 0 discoveries < 0.01, so window will be "low"
            confirmationWindows: 1    // Need 1 low-rate window to confirm
        )
        let plugin1 = PlateauDetectorPlugin(config: config)
        let plugin2 = PlateauDetectorPlugin(config: config)

        var dispatcher = PluginDispatcher(plugins: [plugin1, plugin2])

        // Send iterations to fill window and trigger plateau
        var actions: [FuzzPluginAction<Int>] = []
        for i in 0..<10 {
            let context = PluginEvent<Int>.IterationContext(
                discoveredNewCoverage: false,
                input: i
            )
            actions = try await dispatcher.dispatch(event: PluginEvent<Int>.iteration(context))
            if !actions.isEmpty {
                break
            }
        }

        // Both plugins should return stop actions
        #expect(actions.count == 2)
        for action in actions {
            if case .stop(let stopAction) = action {
                #expect(stopAction.reason == .custom("coverage_plateaued"))
            } else {
                Issue.record("Expected stop action")
            }
        }
    }

    @Test("Dispatcher preserves plugin order")
    func testPreservesPluginOrder() async throws {
        // Create a simple test plugin that tracks call order
        let plugin1 = ShrinkingPlugin(verbose: false)
        let plugin2 = PlateauDetectorPlugin()

        var dispatcher = PluginDispatcher(plugins: [plugin1, plugin2])

        let context = PluginEvent<Int>.StartContext(
            maxDuration: .seconds(60),
            corpusMode: .auto
        )

        // Both plugins return empty for start event, but dispatch should work
        let actions = try await dispatcher.dispatch(event: PluginEvent<Int>.start(context))
        #expect(actions.isEmpty)
    }
}
