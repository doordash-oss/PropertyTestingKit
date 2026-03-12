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
