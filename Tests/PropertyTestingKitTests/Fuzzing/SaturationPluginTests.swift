//
//  SaturationPluginTests.swift
//  PropertyTestingKitTests
//
//  Tests for SaturationPlugin.
//

import Testing
import Foundation
@testable import PropertyTestingKit

@Suite("SaturationPlugin Actions")
struct SaturationPluginActionTests {

    @Test("Plugin has correct ID")
    func testPluginId() async {
        let plugin = SaturationPlugin()
        let id = await plugin.id
        #expect(id == "saturation_detector")
    }

    @Test("Plugin returns stop action when saturated")
    func testStopWhenSaturated() async throws {
        let config = SaturationPlateauDetector.Config(
            minSaturation: 0.9,
            minGrowthRate: 0.01,
            windowSize: 10,
            confirmationWindows: 1
        )
        let plugin = SaturationPlugin(config: config)

        // Simulate iterations without discovery to reach saturation
        var stoppedAt: Int?
        for i in 0..<500 {
            let context = PluginEvent<Int>.IterationContext(
                discoveredNewCoverage: false,
                input: i
            )
            let actions = try await plugin.handle(event: PluginEvent<Int>.iteration(context))

            if !actions.isEmpty {
                if case .stop(let stopAction) = actions[0] {
                    #expect(stopAction.reason == .custom("saturation_plateau"))
                    stoppedAt = i
                    break
                }
            }
        }

        #expect(stoppedAt != nil, "Plugin should have triggered stop")
    }
}
