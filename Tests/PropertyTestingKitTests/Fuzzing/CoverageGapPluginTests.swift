//
//  CoverageGapPluginTests.swift
//  PropertyTestingKitTests
//
//  Tests for CoverageGapPlugin.
//

import Testing
import Foundation
@testable import PropertyTestingKit

@Suite("CoverageGapPlugin Actions")
struct CoverageGapPluginActionTests {

    @Test("Plugin has correct ID")
    func testPluginId() {
        let plugin = CoverageGapPlugin()
        #expect(plugin.id == "coverage_gap")
    }

    @Test("Plugin returns empty for non-end events")
    func testNonEndEventsReturnEmpty() async throws {
        let plugin = CoverageGapPlugin()

        let startContext = PluginEvent<Int>.StartContext(
            maxDuration: .seconds(60),
            corpusMode: .auto
        )
        let actions = try await plugin.handle(event: PluginEvent<Int>.start(startContext))
        #expect(actions.isEmpty)
    }
}
