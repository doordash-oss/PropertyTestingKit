//
//  ShrinkingPluginTests.swift
//  PropertyTestingKitTests
//
//  Tests for ShrinkingPlugin.
//

import Testing
import Foundation
@testable import PropertyTestingKit

@Suite("ShrinkingPlugin")
struct ShrinkingPluginTests {

    @Test("Plugin has correct ID")
    func testPluginId() {
        let plugin = ShrinkingPlugin()
        #expect(plugin.id == "shrinking")
    }

    @Test("Plugin returns empty actions for non-failure events")
    func testNonFailureEventsReturnEmpty() async throws {
        let plugin = ShrinkingPlugin()

        // Test start event
        let startContext = PluginEvent<Int>.StartContext(
            maxDuration: .seconds(60),
            corpusMode: .auto
        )
        let startActions = try await plugin.handle(event: PluginEvent<Int>.start(startContext))
        #expect(startActions.isEmpty)

        // Test iteration event
        let iterationContext = PluginEvent<Int>.IterationContext(
            discoveredNewCoverage: true,
            input: 42
        )
        let iterationActions = try await plugin.handle(event: PluginEvent<Int>.iteration(iterationContext))
        #expect(iterationActions.isEmpty)

        // Test end event
        let endContext = PluginEvent<Int>.EndContext(
            totalCoveredIndices: Set([1, 2, 3]),
            projectPath: nil,
            sourceLocation: SourceLocation(fileID: #fileID, filePath: #filePath, line: #line, column: 1)
        )
        let endActions = try await plugin.handle(event: PluginEvent<Int>.end(endContext))
        #expect(endActions.isEmpty)
    }

    @Test("Plugin returns actions for failure event")
    func testFailureEventReturnsActions() async throws {
        let plugin = ShrinkingPlugin()

        // Create a failure context with an array that can be shrunk
        let failureContext = PluginEvent<[Int]>.FailureFoundContext(
            input: [1, 2, 3, 42, 5],
            test: { input in
                // Fail if array contains 42
                if input.contains(42) {
                    throw ShrinkingTestError.expected
                }
            },
            sourceLocation: SourceLocation(fileID: #fileID, filePath: #filePath, line: #line, column: 1),
            coverageSignature: CoverageSignature(edges: Set<UInt32>([]))
        )

        let actions = try await plugin.handle(event: PluginEvent<[Int]>.failureFound(failureContext))

        // Should return 3 actions: selectForMutation, submitToCorpus, recordIssue
        #expect(actions.count == 3)

        // Verify action types
        var hasSelectForMutation = false
        var hasSubmitToCorpus = false
        var hasRecordIssue = false

        for action in actions {
            switch action {
            case .selectForMutation:
                hasSelectForMutation = true
            case .submitToCorpus:
                hasSubmitToCorpus = true
            case .recordIssue:
                hasRecordIssue = true
            default:
                break
            }
        }

        #expect(hasSelectForMutation)
        #expect(hasSubmitToCorpus)
        #expect(hasRecordIssue)
    }

    @Test("Plugin shrinks input to minimal failing case")
    func testShrinkingMinimizesInput() async throws {
        let plugin = ShrinkingPlugin()

        let failureContext = PluginEvent<[Int]>.FailureFoundContext(
            input: [1, 2, 3, 42, 5, 6, 7],
            test: { input in
                if input.contains(42) {
                    throw ShrinkingTestError.expected
                }
            },
            sourceLocation: SourceLocation(fileID: #fileID, filePath: #filePath, line: #line, column: 1),
            coverageSignature: CoverageSignature(edges: Set<UInt32>([]))
        )

        let actions = try await plugin.handle(event: PluginEvent<[Int]>.failureFound(failureContext))

        // Find the selectForMutation action and check the shrunk input
        for action in actions {
            if case .selectForMutation(let selectAction) = action {
                // The shrunk input should be smaller than original and still contain 42
                #expect(selectAction.input.count < 7)
                #expect(selectAction.input.contains(42))
            }
        }
    }
}

private enum ShrinkingTestError: Error {
    case expected
}
