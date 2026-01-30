//
//  STADSPluginTests.swift
//  PropertyTestingKitTests
//
//  Tests for STADSPlugin.
//

import Testing
import Foundation
@testable import PropertyTestingKit

@Suite("STADSPlugin Actions")
struct STADSPluginActionTests {

    @Test("Plugin has correct ID")
    func testPluginId() {
        let plugin = STADSPlugin()
        #expect(plugin.id == "stads_detector")
    }

    @Test("Plugin returns empty for non-iteration events")
    func testNonIterationEventsReturnEmpty() async throws {
        let plugin = STADSPlugin()

        let endContext = AsyncPluginEvent<Int>.EndContext(
            totalCoveredIndices: Set([1, 2, 3]),
            projectPath: nil,
            sourceLocation: SourceLocation(fileID: #fileID, filePath: #filePath, line: #line, column: 1)
        )
        let actions = try await plugin.handleAsync(event: AsyncPluginEvent<Int>.end(endContext))
        #expect(actions.isEmpty)
    }

    @Test("Plugin returns stop action when probability drops")
    func testStopWhenProbabilityDrops() {
        let config = STADSPlateauDetector.Config(
            minDiscoveryProbability: 0.5,
            confirmationChecks: 1,
            checkInterval: 10
        )
        let plugin = STADSPlugin(config: config)

        // Simulate many iterations without discovery to drop probability
        var stoppedAt: Int?
        for i in 0..<500 {
            let context = SyncPluginEvent<Int>.IterationContext(
                discoveredNewCoverage: false,
                input: i
            )
            let actions = plugin.handle(event: SyncPluginEvent<Int>.iteration(context))

            if !actions.isEmpty {
                if case .stop(let stopAction) = actions[0] {
                    #expect(stopAction.reason == .custom("stads_plateau"))
                    stoppedAt = i
                    break
                }
            }
        }

        #expect(stoppedAt != nil, "Plugin should have triggered stop")
    }
}
