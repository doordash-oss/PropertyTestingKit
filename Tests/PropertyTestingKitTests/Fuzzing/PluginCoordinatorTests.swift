//
//  PluginCoordinatorTests.swift
//  PropertyTestingKitTests
//
//  Tests for PluginCoordinator async message queue coordination.
//

import Testing
import Foundation
@testable import PropertyTestingKit

@Suite("PluginCoordinator")
struct PluginCoordinatorTests {

    // MARK: - Test Plugin

    /// A test plugin that tracks received events and returns configurable actions.
    actor CountingPlugin: FuzzPlugin {
        nonisolated let id: String = "counting"

        private var receivedIterationCount: Int = 0
        private var receivedStartCount: Int = 0
        private var receivedEndCount: Int = 0
        let returnActionOnNewCoverage: Bool

        init(returnActionOnNewCoverage: Bool = true) {
            self.returnActionOnNewCoverage = returnActionOnNewCoverage
        }

        var iterationCount: Int {
            get async { receivedIterationCount }
        }

        var startCount: Int {
            get async { receivedStartCount }
        }

        var endCount: Int {
            get async { receivedEndCount }
        }

        nonisolated func handle<each T: Sendable>(
            event: PluginEvent<repeat each T>
        ) async throws -> [FuzzPluginAction<repeat each T>] {
            switch event {
            case .iteration(let context):
                await incrementIterationCount()
                if returnActionOnNewCoverage && context.discoveredNewCoverage {
                    return [.selectForMutation(.init(input: context.input))]
                }
                return []
            case .start:
                await incrementStartCount()
                return []
            case .end:
                await incrementEndCount()
                return []
            case .failureFound:
                return []
            }
        }

        private func incrementIterationCount() {
            receivedIterationCount += 1
        }

        private func incrementStartCount() {
            receivedStartCount += 1
        }

        private func incrementEndCount() {
            receivedEndCount += 1
        }
    }

    // MARK: - Tests

    @Test("All submitted events are processed before completion")
    func testAllEventsProcessedBeforeCompletion() async throws {
        let plugin = CountingPlugin()

        let coordinator = PluginCoordinator<Int>(plugins: [plugin])
        await coordinator.start()

        // Start action consumer task
        let actionCount = SyncBox(0)
        let actionConsumerTask = Task {
            while !coordinator.actions.isClosed {
                if coordinator.actions.dequeue() != nil {
                    actionCount.update { $0 += 1 }
                } else {
                    await Task.yield()
                }
            }
            // Drain remaining
            while coordinator.actions.dequeue() != nil {
                actionCount.update { $0 += 1 }
            }
        }

        // Submit many events rapidly (fire-and-forget)
        let eventCount = 100
        for i in 0..<eventCount {
            coordinator.send(event: .iteration(.init(
                discoveredNewCoverage: false,
                input: i
            )))
        }

        // Close and wait - all events should be processed
        await coordinator.closeAndAwaitCompletion()
        await actionConsumerTask.value

        #expect(await plugin.iterationCount == eventCount)
    }

    @Test("All actions are produced before completion")
    func testAllActionsProducedBeforeCompletion() async throws {
        let plugin = CountingPlugin(returnActionOnNewCoverage: true)

        let coordinator = PluginCoordinator<Int>(plugins: [plugin])
        await coordinator.start()

        // Start action consumer task
        let executedInputs = SyncBox<[Int]>([])
        let actionConsumerTask = Task {
            while !coordinator.actions.isClosed {
                if let action = coordinator.actions.dequeue() {
                    if case .selectForMutation(let mutation) = action {
                        executedInputs.update { $0.append(mutation.input) }
                    }
                } else {
                    await Task.yield()
                }
            }
            // Drain remaining
            while let action = coordinator.actions.dequeue() {
                if case .selectForMutation(let mutation) = action {
                    executedInputs.update { $0.append(mutation.input) }
                }
            }
        }

        // Submit events that will generate actions
        let eventCount = 50
        for i in 0..<eventCount {
            coordinator.send(event: .iteration(.init(
                discoveredNewCoverage: true,  // Will generate action
                input: i
            )))
        }

        await coordinator.closeAndAwaitCompletion()
        await actionConsumerTask.value

        // All actions should have been produced and consumed
        let executed = executedInputs.value
        #expect(executed.count == eventCount)

        // Verify all inputs were processed (order may vary due to concurrency)
        #expect(Set(executed) == Set(0..<eventCount))
    }

    @Test("Events submitted just before close are still processed")
    func testEventsSubmittedBeforeCloseAreProcessed() async throws {
        let plugin = CountingPlugin()

        let coordinator = PluginCoordinator<Int>(plugins: [plugin])
        await coordinator.start()

        // Start action consumer task
        let actionCount = SyncBox(0)
        let actionConsumerTask = Task {
            while !coordinator.actions.isClosed {
                if coordinator.actions.dequeue() != nil {
                    actionCount.update { $0 += 1 }
                } else {
                    await Task.yield()
                }
            }
            // Drain remaining
            while coordinator.actions.dequeue() != nil {
                actionCount.update { $0 += 1 }
            }
        }

        // Submit events and immediately close
        for i in 0..<10 {
            coordinator.send(event: .iteration(.init(
                discoveredNewCoverage: true,
                input: i
            )))
        }

        // Close immediately after submitting
        await coordinator.closeAndAwaitCompletion()
        await actionConsumerTask.value

        // All events and actions should still be processed
        #expect(await plugin.iterationCount == 10)
        #expect(actionCount.value == 10)
    }

    @Test("Empty coordinator completes immediately")
    func testEmptyCoordinatorCompletesImmediately() async throws {
        let coordinator = PluginCoordinator<Int>(plugins: [])

        await coordinator.start()

        // Start action consumer task (will complete immediately when channel closes)
        let actionConsumerTask = Task {
            while !coordinator.actions.isClosed {
                if coordinator.actions.dequeue() != nil {
                    // ignore
                } else {
                    await Task.yield()
                }
            }
            // Drain remaining
            while coordinator.actions.dequeue() != nil { }
        }

        // Should complete immediately with no events
        await coordinator.closeAndAwaitCompletion()
        await actionConsumerTask.value
    }

    @Test("Coordinator handles mixed event types")
    func testHandlesMixedEventTypes() async throws {
        let plugin = CountingPlugin()

        let coordinator = PluginCoordinator<Int>(plugins: [plugin])
        await coordinator.start()

        // Start action consumer task
        let actionConsumerTask = Task {
            while !coordinator.actions.isClosed {
                if coordinator.actions.dequeue() != nil {
                    // ignore
                } else {
                    await Task.yield()
                }
            }
            // Drain remaining
            while coordinator.actions.dequeue() != nil { }
        }

        // Submit different event types
        coordinator.send(event: .start(.init(
            maxDuration: .seconds(60),
            corpusMode: .auto
        )))

        for i in 0..<5 {
            coordinator.send(event: .iteration(.init(
                discoveredNewCoverage: false,
                input: i
            )))
        }

        coordinator.send(event: .end(.init(
            totalCoveredIndices: Set([1, 2, 3]),
            projectPath: nil,
            sourceLocation: #_sourceLocation
        )))

        await coordinator.closeAndAwaitCompletion()
        await actionConsumerTask.value

        #expect(await plugin.startCount == 1)
        #expect(await plugin.iterationCount == 5)
        #expect(await plugin.endCount == 1)
    }

}
