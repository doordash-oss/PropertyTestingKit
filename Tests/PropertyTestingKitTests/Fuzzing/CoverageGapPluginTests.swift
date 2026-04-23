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
//  CoverageGapPluginTests.swift
//  PropertyTestingKitTests
//
//  Tests for the coverage gap handler.
//

import Testing
import Foundation
@testable import PropertyTestingKit

@Suite("Coverage Gap Handler Actions")
struct CoverageGapHandlerActionTests {

    @Test("Handler has correct ID")
    func testHandlerId() {
        let handler: FuzzPluginHandler<Int> = .coverageGap()
        #expect(handler.id == "coverage_gap")
    }

    @Test("Handler returns empty for non-end events")
    func testNonEndEventsReturnEmpty() async throws {
        let handler: FuzzPluginHandler<Int> = .coverageGap()

        // Sync events should always return empty
        let iterationContext = SyncPluginEvent<Int>.IterationContext(
            discoveredNewCoverage: true,
            input: 42
        )
        let syncActions = handler.handleSync(SyncPluginEvent<Int>.iteration(iterationContext))
        #expect(syncActions.isEmpty)

        // Start event should pre-warm but return empty actions
        let startContext = AsyncPluginEvent<Int>.StartContext(
            maxDuration: .seconds(60),
            corpusMode: .auto
        )
        let startActions = try await handler.handleAsync(AsyncPluginEvent<Int>.start(startContext))
        #expect(startActions.isEmpty)
    }
}
