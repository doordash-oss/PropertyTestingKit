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

//  Tests for the shrinking handler.
//

import Testing
import Foundation
@testable import PropertyTestingKit

@Suite("Shrinking Handler")
struct ShrinkingHandlerTests {

    @Test("Handler has correct ID")
    func testHandlerId() {
        let handler: FuzzPluginHandler<Int> = .shrinking()
        #expect(handler.id == "shrinking")
    }

    @Test("Handler returns empty actions for non-failure events")
    func testNonFailureEventsReturnEmpty() async throws {
        let handler: FuzzPluginHandler<Int> = .shrinking()

        // Test start event (async)
        let startContext = AsyncPluginEvent<Int>.StartContext(
            maxDuration: .seconds(60)
        )
        let startActions = try await handler.handleAsync(AsyncPluginEvent<Int>.start(startContext))
        #expect(startActions.isEmpty)

        // Test iteration event (sync)
        let iterationContext = SyncPluginEvent<Int>.IterationContext(
            input: 42,
            newCoverage: SparseCoverage()
        )
        let iterationActions = handler.handleSync(SyncPluginEvent<Int>.iteration(iterationContext))
        #expect(iterationActions.isEmpty)

        // Test end event (async)
        let endContext = AsyncPluginEvent<Int>.EndContext(
            totalCoveredIndices: Set([1, 2, 3]),
            projectPath: nil,
            sourceLocation: SourceLocation(fileID: #fileID, filePath: #filePath, line: #line, column: 1)
        )
        let endActions = try await handler.handleAsync(AsyncPluginEvent<Int>.end(endContext))
        #expect(endActions.isEmpty)
    }

    @Test("Handler returns actions for failure event")
    func testFailureEventReturnsActions() async throws {
        let handler: FuzzPluginHandler<[Int]> = .shrinking()

        // Create a failure context with an array that can be shrunk
        let failureContext = AsyncPluginEvent<[Int]>.FailureFoundContext(
            input: [1, 2, 3, 42, 5],
            test: { input in
                // Fail if array contains 42
                if input.contains(42) {
                    throw ShrinkingTestError.expected
                }
            },
            sourceLocation: SourceLocation(fileID: #fileID, filePath: #filePath, line: #line, column: 1),
            sparseCoverage: SparseCoverage()
        )

        let actions = try await handler.handleAsync(AsyncPluginEvent<[Int]>.failureFound(failureContext))

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

    @Test("Handler shrinks input to minimal failing case")
    func testShrinkingMinimizesInput() async throws {
        let handler: FuzzPluginHandler<[Int]> = .shrinking()

        let failureContext = AsyncPluginEvent<[Int]>.FailureFoundContext(
            input: [1, 2, 3, 42, 5, 6, 7],
            test: { input in
                if input.contains(42) {
                    throw ShrinkingTestError.expected
                }
            },
            sourceLocation: SourceLocation(fileID: #fileID, filePath: #filePath, line: #line, column: 1),
            sparseCoverage: SparseCoverage()
        )

        let actions = try await handler.handleAsync(AsyncPluginEvent<[Int]>.failureFound(failureContext))

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
