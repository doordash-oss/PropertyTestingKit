//
//  SaturationPluginTests.swift
//  PropertyTestingKitTests
//
//  Tests for the saturation plateau detector handler.
//

import Testing
import Foundation
@testable import PropertyTestingKit

@Suite("Saturation Handler Actions")
struct SaturationHandlerActionTests {

    @Test("Handler has correct ID")
    func testHandlerId() {
        let handler: FuzzPluginHandler<Int> = .saturationDetector()
        #expect(handler.id == "saturation_detector")
    }

    @Test("Handler returns stop action when saturated")
    func testStopWhenSaturated() {
        let config = SaturationPlateauDetector.Config(
            minSaturation: 0.9,
            minGrowthRate: 0.01,
            windowSize: 10,
            confirmationWindows: 1
        )
        let handler: FuzzPluginHandler<Int> = .saturationDetector(config: config)

        // Simulate iterations without discovery to reach saturation
        var stoppedAt: Int?
        for i in 0..<500 {
            let context = SyncPluginEvent<Int>.IterationContext(
                discoveredNewCoverage: false,
                input: i
            )
            let actions = handler.handleSync(SyncPluginEvent<Int>.iteration(context))

            if !actions.isEmpty {
                if case .stop(let stopAction) = actions[0] {
                    #expect(stopAction.reason == .custom("saturation_plateau"))
                    stoppedAt = i
                    break
                }
            }
        }

        #expect(stoppedAt != nil, "Handler should have triggered stop")
    }
}
