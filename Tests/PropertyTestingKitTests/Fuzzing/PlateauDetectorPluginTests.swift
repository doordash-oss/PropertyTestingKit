// Copyright 2026 DoorDash, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

//  Tests for the plateau detector handler.
//

import Testing
import Foundation
@testable import PropertyTestingKit

@Suite("Plateau Detector Handler")
struct PlateauDetectorHandlerTests {

    @Test("Handler has correct ID")
    func testHandlerId() {
        let handler: AnalysisHandler<Int> = .plateauDetector()
        #expect(handler.id == "plateau_detector")
    }

    @Test("Handler returns empty for async events")
    func testAsyncEventsReturnEmpty() async throws {
        let handler: AnalysisHandler<Int> = .plateauDetector()

        let startContext = AsyncPluginEvent<Int>.StartContext(
            maxDuration: .seconds(60)
        )
        let actions = try await handler.handleAsync(AsyncPluginEvent<Int>.start(startContext))
        #expect(actions.isEmpty)
    }

    @Test("Handler does not stop when coverage is being discovered")
    func testNoStopWithCoverageDiscovery() {
        let handler: AnalysisHandler<Int> = .plateauDetector()

        // Simulate iterations with new coverage each time
        for i in 0..<50 {
            let context = SyncPluginEvent<Int>.IterationContext(
                input: i,
                newCoverage: SparseCoverage()
            )
            let actions = handler.handleSync(SyncPluginEvent<Int>.iteration(context))
            #expect(actions.isEmpty, "Should not stop when discovering coverage")
        }
    }

    @Test("Handler returns stop action after plateau")
    func testStopAfterPlateau() {
        // Configure with small window for faster testing
        // minDiscoveryRate: 0.01 means 0 discoveries per 10 iterations is "low"
        // confirmationWindows: 2 means we need 2 consecutive low windows
        let config = SimpleCoveragePlateauDetector.Config(
            windowSize: 10,
            minDiscoveryRate: 0.01,   // 0 discoveries < 0.01, so window will be "low"
            confirmationWindows: 2     // Need 2 consecutive low-rate windows
        )
        let handler: AnalysisHandler<Int> = .plateauDetector(config: config)

        // Simulate iterations without new coverage to trigger plateau
        // Need: 10 iterations to fill first window, then 2+ windows of low rate
        var stoppedAt: Int?
        for i in 0..<100 {
            let context = SyncPluginEvent<Int>.IterationContext(
                input: i
            )
            let actions = handler.handleSync(SyncPluginEvent<Int>.iteration(context))

            if !actions.isEmpty {
                // Should be a stop action
                if case .stop(let stopAction) = actions[0] {
                    #expect(stopAction.reason == .custom("coverage_plateaued"))
                    stoppedAt = i
                    break
                }
            }
        }

        #expect(stoppedAt != nil, "Handler should have triggered stop")
    }
}
