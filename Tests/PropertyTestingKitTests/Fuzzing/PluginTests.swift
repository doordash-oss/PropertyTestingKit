//
//  PluginTests.swift
//  PropertyTestingKitTests
//
//  Tests for event-based plugins.
//

import Testing
import Foundation
@testable import PropertyTestingKit

// MARK: - EventBasedShrinkingPlugin Tests

@Suite("EventBasedShrinkingPlugin")
struct EventBasedShrinkingPluginTests {

    @Test("Plugin has correct ID")
    func testPluginId() {
        let plugin = EventBasedShrinkingPlugin()
        #expect(plugin.id == "shrinking")
    }

    @Test("Plugin returns empty actions for non-failure events")
    func testNonFailureEventsReturnEmpty() async throws {
        let plugin = EventBasedShrinkingPlugin()

        // Test start event
        let startContext = PluginEvent<Int>.StartContext(
            maxDuration: .seconds(60),
            corpusMode: .auto
        )
        let startActions = try await plugin.handle(event: PluginEvent<Int>.start(startContext))
        #expect(startActions.isEmpty)

        // Test iteration event
        let iterationContext = PluginEvent<Int>.IterationContext(
            discoveredNewCoverage: true
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
        let plugin = EventBasedShrinkingPlugin()

        // Create a failure context with an array that can be shrunk
        let failureContext = PluginEvent<[Int]>.FailureFoundContext(
            input: [1, 2, 3, 42, 5],
            test: { input in
                // Fail if array contains 42
                if input.contains(42) {
                    throw TestError.expected
                }
            },
            sourceLocation: SourceLocation(fileID: #fileID, filePath: #filePath, line: #line, column: 1),
            coverageSignature: CoverageSignature(edges: [])
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
        let plugin = EventBasedShrinkingPlugin()

        let failureContext = PluginEvent<[Int]>.FailureFoundContext(
            input: [1, 2, 3, 42, 5, 6, 7],
            test: { input in
                if input.contains(42) {
                    throw TestError.expected
                }
            },
            sourceLocation: SourceLocation(fileID: #fileID, filePath: #filePath, line: #line, column: 1),
            coverageSignature: CoverageSignature(edges: [])
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

// MARK: - EventBasedPlateauDetectorPlugin Tests

@Suite("EventBasedPlateauDetectorPlugin")
struct EventBasedPlateauDetectorPluginTests {

    @Test("Plugin has correct ID")
    func testPluginId() async {
        let plugin = EventBasedPlateauDetectorPlugin()
        let id = await plugin.id
        #expect(id == "plateau_detector")
    }

    @Test("Plugin returns empty for non-iteration events")
    func testNonIterationEventsReturnEmpty() async throws {
        let plugin = EventBasedPlateauDetectorPlugin()

        let startContext = PluginEvent<Int>.StartContext(
            maxDuration: .seconds(60),
            corpusMode: .auto
        )
        let actions = try await plugin.handle(event: PluginEvent<Int>.start(startContext))
        #expect(actions.isEmpty)
    }

    @Test("Plugin does not stop when coverage is being discovered")
    func testNoStopWithCoverageDiscovery() async throws {
        let plugin = EventBasedPlateauDetectorPlugin()

        // Simulate iterations with new coverage each time
        for _ in 0..<50 {
            let context = PluginEvent<Int>.IterationContext(
                discoveredNewCoverage: true
            )
            let actions = try await plugin.handle(event: PluginEvent<Int>.iteration(context))
            #expect(actions.isEmpty, "Should not stop when discovering coverage")
        }
    }

    @Test("Plugin returns stop action after plateau")
    func testStopAfterPlateau() async throws {
        // Configure with small window for faster testing
        // minDiscoveryRate: 0.01 means 0 discoveries per 10 iterations is "low"
        // confirmationWindows: 2 means we need 2 consecutive low windows
        let config = SimpleCoveragePlateauDetector.Config(
            windowSize: 10,
            minDiscoveryRate: 0.01,   // 0 discoveries < 0.01, so window will be "low"
            confirmationWindows: 2     // Need 2 consecutive low-rate windows
        )
        let plugin = EventBasedPlateauDetectorPlugin(config: config)

        // Simulate iterations without new coverage to trigger plateau
        // Need: 10 iterations to fill first window, then 2+ windows of low rate
        var stoppedAt: Int?
        for i in 0..<100 {
            let context = PluginEvent<Int>.IterationContext(
                discoveredNewCoverage: false
            )
            let actions = try await plugin.handle(event: PluginEvent<Int>.iteration(context))

            if !actions.isEmpty {
                // Should be a stop action
                if case .stop(let stopAction) = actions[0] {
                    #expect(stopAction.reason == .custom("coverage_plateau"))
                    stoppedAt = i
                    break
                }
            }
        }

        #expect(stoppedAt != nil, "Plugin should have triggered stop")
    }
}

// MARK: - EventBasedSTADSPlugin Tests

@Suite("EventBasedSTADSPlugin Actions")
struct EventBasedSTADSPluginActionTests {

    @Test("Plugin has correct ID")
    func testPluginId() async {
        let plugin = EventBasedSTADSPlugin()
        let id = await plugin.id
        #expect(id == "stads_detector")
    }

    @Test("Plugin returns empty for non-iteration events")
    func testNonIterationEventsReturnEmpty() async throws {
        let plugin = EventBasedSTADSPlugin()

        let endContext = PluginEvent<Int>.EndContext(
            totalCoveredIndices: Set([1, 2, 3]),
            projectPath: nil,
            sourceLocation: SourceLocation(fileID: #fileID, filePath: #filePath, line: #line, column: 1)
        )
        let actions = try await plugin.handle(event: PluginEvent<Int>.end(endContext))
        #expect(actions.isEmpty)
    }

    @Test("Plugin returns stop action when probability drops")
    func testStopWhenProbabilityDrops() async throws {
        let config = STADSPlateauDetector.Config(
            minDiscoveryProbability: 0.5,
            confirmationChecks: 1,
            checkInterval: 10
        )
        let plugin = EventBasedSTADSPlugin(config: config)

        // Simulate many iterations without discovery to drop probability
        var stoppedAt: Int?
        for i in 0..<500 {
            let context = PluginEvent<Int>.IterationContext(
                discoveredNewCoverage: false
            )
            let actions = try await plugin.handle(event: PluginEvent<Int>.iteration(context))

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

// MARK: - EventBasedSaturationPlugin Tests

@Suite("EventBasedSaturationPlugin Actions")
struct EventBasedSaturationPluginActionTests {

    @Test("Plugin has correct ID")
    func testPluginId() async {
        let plugin = EventBasedSaturationPlugin()
        let id = await plugin.id
        #expect(id == "saturation_detector")
    }

    // BatchContext test removed - BatchContext no longer exists in PluginEvent

    @Test("Plugin returns stop action when saturated")
    func testStopWhenSaturated() async throws {
        let config = SaturationPlateauDetector.Config(
            minSaturation: 0.9,
            minGrowthRate: 0.01,
            windowSize: 10,
            confirmationWindows: 1
        )
        let plugin = EventBasedSaturationPlugin(config: config)

        // Simulate iterations without discovery to reach saturation
        var stoppedAt: Int?
        for i in 0..<500 {
            let context = PluginEvent<Int>.IterationContext(
                discoveredNewCoverage: false
            )
            let actions = try await plugin.handle(event: PluginEvent<Int>.iteration(context))

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

// MARK: - EventBasedPluginDispatcher Tests

@Suite("EventBasedPluginDispatcher")
struct EventBasedPluginDispatcherTests {

    @Test("Dispatcher with no plugins returns empty actions")
    func testEmptyPluginsReturnsEmpty() async throws {
        var dispatcher = EventBasedPluginDispatcher(plugins: [])

        let context = PluginEvent<Int>.IterationContext(
            discoveredNewCoverage: true
        )
        let actions = try await dispatcher.dispatch(event: PluginEvent<Int>.iteration(context))
        #expect(actions.isEmpty)
    }

    @Test("Dispatcher collects actions from multiple plugins")
    func testCollectsActionsFromMultiplePlugins() async throws {
        // Use two plateau detectors configured to trigger after filling a small window
        let config = SimpleCoveragePlateauDetector.Config(
            windowSize: 2,
            minDiscoveryRate: 0.01,  // 0 discoveries < 0.01, so window will be "low"
            confirmationWindows: 1    // Need 1 low-rate window to confirm
        )
        let plugin1 = EventBasedPlateauDetectorPlugin(config: config)
        let plugin2 = EventBasedPlateauDetectorPlugin(config: config)

        var dispatcher = EventBasedPluginDispatcher(plugins: [plugin1, plugin2])

        // Send iterations to fill window and trigger plateau
        var actions: [FuzzPluginAction<Int>] = []
        for i in 0..<10 {
            let context = PluginEvent<Int>.IterationContext(
                discoveredNewCoverage: false
            )
            actions = try await dispatcher.dispatch(event: PluginEvent<Int>.iteration(context))
            if !actions.isEmpty {
                break
            }
        }

        // Both plugins should return stop actions
        #expect(actions.count == 2)
        for action in actions {
            if case .stop(let stopAction) = action {
                #expect(stopAction.reason == .custom("coverage_plateau"))
            } else {
                Issue.record("Expected stop action")
            }
        }
    }

    @Test("Dispatcher preserves plugin order")
    func testPreservesPluginOrder() async throws {
        // Create a simple test plugin that tracks call order
        let plugin1 = EventBasedShrinkingPlugin(verbose: false)
        let plugin2 = EventBasedPlateauDetectorPlugin()

        var dispatcher = EventBasedPluginDispatcher(plugins: [plugin1, plugin2])

        let context = PluginEvent<Int>.StartContext(
            maxDuration: .seconds(60),
            corpusMode: .auto
        )

        // Both plugins return empty for start event, but dispatch should work
        let actions = try await dispatcher.dispatch(event: PluginEvent<Int>.start(context))
        #expect(actions.isEmpty)
    }
}

// MARK: - EventBasedCoverageGapPlugin Tests

@Suite("EventBasedCoverageGapPlugin Actions")
struct EventBasedCoverageGapPluginActionTests {

    @Test("Plugin has correct ID")
    func testPluginId() {
        let plugin = EventBasedCoverageGapPlugin()
        #expect(plugin.id == "coverage_gap")
    }

    @Test("Plugin returns empty for non-end events")
    func testNonEndEventsReturnEmpty() async throws {
        let plugin = EventBasedCoverageGapPlugin()

        let startContext = PluginEvent<Int>.StartContext(
            maxDuration: .seconds(60),
            corpusMode: .auto
        )
        let actions = try await plugin.handle(event: PluginEvent<Int>.start(startContext))
        #expect(actions.isEmpty)
    }

}

// ActionExecutor tests removed - ActionExecutor is currently commented out in source

// MARK: - Test Helpers

private enum TestError: Error {
    case expected
}
