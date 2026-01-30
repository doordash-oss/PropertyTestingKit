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
    func testPluginId() {
        let plugin = SaturationPlugin()
        #expect(plugin.id == "saturation_detector")
    }

    @Test("Plugin returns stop action when saturated")
    func testStopWhenSaturated() {
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
            let context = SyncPluginEvent<Int>.IterationContext(
                discoveredNewCoverage: false,
                input: i
            )
            let actions = plugin.handle(event: SyncPluginEvent<Int>.iteration(context))

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
