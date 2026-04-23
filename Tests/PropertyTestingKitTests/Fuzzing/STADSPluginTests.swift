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

//  Tests for the STADS plateau detector handler.
//

import Testing
import Foundation
@testable import PropertyTestingKit

@Suite("STADS Handler Actions")
struct STADSHandlerActionTests {

    @Test("Handler has correct ID")
    func testHandlerId() {
        let handler: FuzzPluginHandler<Int> = .stadsDetector()
        #expect(handler.id == "stads_detector")
    }

    @Test("Handler returns empty for async events")
    func testAsyncEventsReturnEmpty() async throws {
        let handler: FuzzPluginHandler<Int> = .stadsDetector()

        let endContext = AsyncPluginEvent<Int>.EndContext(
            totalCoveredIndices: Set([1, 2, 3]),
            projectPath: nil,
            sourceLocation: SourceLocation(fileID: #fileID, filePath: #filePath, line: #line, column: 1)
        )
        let actions = try await handler.handleAsync(AsyncPluginEvent<Int>.end(endContext))
        #expect(actions.isEmpty)
    }

    @Test("Handler returns stop action when probability drops")
    func testStopWhenProbabilityDrops() {
        let config = STADSPlateauDetector.Config(
            minDiscoveryProbability: 0.5,
            confirmationChecks: 1,
            checkInterval: 10
        )
        let handler: FuzzPluginHandler<Int> = .stadsDetector(config: config)

        // Simulate many iterations without discovery to drop probability
        var stoppedAt: Int?
        for i in 0..<500 {
            let context = SyncPluginEvent<Int>.IterationContext(
                discoveredNewCoverage: false,
                input: i
            )
            let actions = handler.handleSync(SyncPluginEvent<Int>.iteration(context))

            if !actions.isEmpty {
                if case .stop(let stopAction) = actions[0] {
                    #expect(stopAction.reason == .custom("stads_plateau"))
                    stoppedAt = i
                    break
                }
            }
        }

        #expect(stoppedAt != nil, "Handler should have triggered stop")
    }
}
