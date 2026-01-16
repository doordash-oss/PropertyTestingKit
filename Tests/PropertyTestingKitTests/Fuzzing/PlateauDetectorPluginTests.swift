//
//  PlateauDetectorPluginTests.swift
//  PropertyTestingKitTests
//
//  Tests for PlateauDetectorPlugin.
//

import Testing
import Foundation
@testable import PropertyTestingKit

@Suite("PlateauDetectorPlugin")
struct PlateauDetectorPluginTests {

    @Test("Plugin has correct ID")
    func testPluginId() async {
        let plugin = PlateauDetectorPlugin()
        let id = await plugin.id
        #expect(id == "plateau_detector")
    }

    @Test("Plugin returns empty for non-iteration events")
    func testNonIterationEventsReturnEmpty() async throws {
        let plugin = PlateauDetectorPlugin()

        let startContext = PluginEvent<Int>.StartContext(
            maxDuration: .seconds(60),
            corpusMode: .auto
        )
        let actions = try await plugin.handle(event: PluginEvent<Int>.start(startContext))
        #expect(actions.isEmpty)
    }

    @Test("Plugin does not stop when coverage is being discovered")
    func testNoStopWithCoverageDiscovery() async throws {
        let plugin = PlateauDetectorPlugin()

        // Simulate iterations with new coverage each time
        for i in 0..<50 {
            let context = PluginEvent<Int>.IterationContext(
                discoveredNewCoverage: true,
                input: i
            )
            let actions = try await plugin.handle(event: PluginEvent<Int>.iteration(context))
            #expect(actions.isEmpty, "Should not stop when discovering coverage")
        }
    }

    @Test("Plugin returns stop action after plateau")
    func testStopAfterPlateau() async throws {
        // Configure with small window for faster testing
        // minDiscoveryRate: 0.01 means 0 discoveries per 10 iterations is "low"
        // confirmationWindows: 2 means we need 2 consecutive low windows
        let config = SimpleCoveragePlateauDetector.Config(
            windowSize: 10,
            minDiscoveryRate: 0.01,   // 0 discoveries < 0.01, so window will be "low"
            confirmationWindows: 2     // Need 2 consecutive low-rate windows
        )
        let plugin = PlateauDetectorPlugin(config: config)

        // Simulate iterations without new coverage to trigger plateau
        // Need: 10 iterations to fill first window, then 2+ windows of low rate
        var stoppedAt: Int?
        for i in 0..<100 {
            let context = PluginEvent<Int>.IterationContext(
                discoveredNewCoverage: false,
                input: i
            )
            let actions = try await plugin.handle(event: PluginEvent<Int>.iteration(context))

            if !actions.isEmpty {
                // Should be a stop action
                if case .stop(let stopAction) = actions[0] {
                    #expect(stopAction.reason == .custom("coverage_plateaued"))
                    stoppedAt = i
                    break
                }
            }
        }

        #expect(stoppedAt != nil, "Plugin should have triggered stop")
    }
}
