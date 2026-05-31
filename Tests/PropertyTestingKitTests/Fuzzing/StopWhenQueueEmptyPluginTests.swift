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

//  Tests for the stop-when-queue-empty handler.
//

import Testing
import Foundation
@testable import PropertyTestingKit

@Suite("Stop When Queue Empty Handler")
struct StopWhenQueueEmptyHandlerTests {

    @Test("Handler has correct ID")
    func handlerId() {
        let handler: FuzzPluginHandler<Int> = .stopWhenQueueEmpty()
        #expect(handler.id == "stop_when_queue_empty")
    }

    @Test("Does not stop while the queue still has inputs")
    func doesNotStopMidQueue() {
        let handler: FuzzPluginHandler<Int> = .stopWhenQueueEmpty()

        // An ordinary iteration (input came from the queue) must not stop the run.
        let context = SyncPluginEvent<Int>.IterationContext(
            discoveredNewCoverage: false,
            input: 7,
            fromMutationQueue: true
        )
        let actions = handler.handleSync(.iteration(context))
        #expect(actions.isEmpty)
    }

    @Test("Stops the run when the queue drains")
    func stopsOnQueueEmpty() {
        let handler: FuzzPluginHandler<Int> = .stopWhenQueueEmpty()

        let actions = handler.handleSync(.queueEmpty)

        #expect(actions.count == 1)
        guard case let .stop(stopAction) = actions.first else {
            Issue.record("Expected a .stop action, got \(actions)")
            return
        }
        #expect(stopAction.reason.rawValue == "regression")
    }

    @Test("Stop reason is configurable")
    func customStopReason() {
        let handler: FuzzPluginHandler<Int> = .stopWhenQueueEmpty(reason: .custom("done"))

        let actions = handler.handleSync(.queueEmpty)

        guard case let .stop(stopAction) = actions.first else {
            Issue.record("Expected a .stop action, got \(actions)")
            return
        }
        #expect(stopAction.reason.rawValue == "done")
    }

    @Test("Engine replays only the seeds and never generates random inputs")
    func engineStopsAfterSeedsWithoutGenerating() async {
        let executed = SyncBox<[Int]>([])
        let seeds = [101, 102, 103]

        let processor = PluginHandlerProcessor(
            handlers: [FuzzPluginHandler<Int>.stopWhenQueueEmpty()]
        )
        let config = FuzzEngineConfig(
            maxDuration: .seconds(60),
            minimizeCorpus: false,
            corpusMode: .refuzzReplace,
            timeLimitCheckInterval: 1
        )
        let engine = FuzzEngine(
            mutators: Int.defaultMutator,
            config: config,
            corpusDirectory: nil
        )

        let result = await engine.run(
            additionalSeeds: seeds,
            processSyncPlugins: { processor.processSync(event: $0, execute: $1) },
            processAsyncPlugins: { await processor.processAsync(isolation: $0, event: $1, execute: $2) },
            test: { input in
                executed.update { $0.append(input) }
            }
        )

        // No fresh random inputs were generated: the run stopped the instant the
        // queue drained, replaying only the seeded inputs.
        #expect(result.stats.generations == 0)
        #expect(result.stats.stopReason.rawValue == "regression")
        // Every seeded input ran, and nothing beyond the seeds did.
        #expect(executed.value.count == result.stats.totalInputs)
        #expect(Set(seeds).isSubset(of: Set(executed.value)))
    }
}
