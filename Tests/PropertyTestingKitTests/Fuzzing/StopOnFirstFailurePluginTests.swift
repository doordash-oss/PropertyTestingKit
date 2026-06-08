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

//  Tests for the stop-on-first-failure analysis plugin.
//

import Testing
import Foundation
@testable import PropertyTestingKit

@Suite("Stop On First Failure Plugin")
struct StopOnFirstFailurePluginTests {

    private func failureEvent() -> AsyncPluginEvent<Int> {
        let context = AsyncPluginEvent<Int>.FailureFoundContext(
            input: 42,
            scheduleBytes: nil,
            test: { _ in },
            sourceLocation: SourceLocation(fileID: #fileID, filePath: #filePath, line: #line, column: 1),
            sparseCoverage: SparseCoverage(indices: [])
        )
        return .failureFound(context)
    }

    @Test("Plugin has correct ID")
    func pluginId() {
        let plugin: AnalysisPlugin<Int> = .stopOnFirstFailure()
        #expect(plugin.id == "stop_on_first_failure")
    }

    @Test("Does not stop on the synchronous iteration hot path")
    func doesNotStopOnIteration() {
        let plugin: AnalysisPlugin<Int> = .stopOnFirstFailure()
        let context = SyncPluginEvent<Int>.IterationContext(
            input: 7, fromMutationQueue: true, queueCount: 3)
        #expect(plugin.handleSync(.iteration(context)).isEmpty)
    }

    @Test("Stops the run when a failure is found")
    func stopsOnFailure() async throws {
        let plugin: AnalysisPlugin<Int> = .stopOnFirstFailure()
        let actions = try await plugin.handleAsync(failureEvent())
        #expect(actions.count == 1)
        guard case let .stop(stopAction) = actions.first else {
            Issue.record("Expected a .stop action, got \(actions)")
            return
        }
        #expect(stopAction.reason.rawValue == "first_failure")
    }

    @Test("Uses a caller-supplied stop reason")
    func customReason() async throws {
        let plugin: AnalysisPlugin<Int> = .stopOnFirstFailure(reason: .custom("counterexample_found"))
        let actions = try await plugin.handleAsync(failureEvent())
        guard case let .stop(stopAction) = actions.first else {
            Issue.record("Expected a .stop action, got \(actions)")
            return
        }
        #expect(stopAction.reason.rawValue == "counterexample_found")
    }

    @Test("Ignores start and end events")
    func ignoresLifecycleEvents() async throws {
        let plugin: AnalysisPlugin<Int> = .stopOnFirstFailure()
        let start = AsyncPluginEvent<Int>.start(.init(maxDuration: .seconds(1)))
        let end = AsyncPluginEvent<Int>.end(.init(
            totalCoveredIndices: [], projectPath: nil,
            sourceLocation: SourceLocation(fileID: #fileID, filePath: #filePath, line: #line, column: 1)))
        #expect(try await plugin.handleAsync(start).isEmpty)
        #expect(try await plugin.handleAsync(end).isEmpty)
    }

    @Test("Is usable inside fuzz(...) via the lifted FuzzPlugin factory")
    func liftedFuzzPlugin() {
        let plugin: FuzzPlugin<Int> = .stopOnFirstFailure()
        #expect(plugin.id == "stop_on_first_failure")
    }
}
