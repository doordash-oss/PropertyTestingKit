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
