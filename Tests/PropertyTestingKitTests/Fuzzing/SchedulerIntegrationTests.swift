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

//  The pool scheduler drives the engine's mutation loop: when the residual
//  queue is empty the engine asks the scheduler what to run next (.mutate an
//  entry or .generate fresh), so mutation scheduling no longer depends on any
//  bus plugin. The flat plugin bus remains for observers.
//

import Testing
@testable import PropertyTestingKit

@Suite("Pool scheduler integration")
struct SchedulerIntegrationTests {

    @Test("Default scheduler sustains the mutation loop without any bus plugins")
    func defaultSchedulerSustainsMutation() async throws {
        let mutatedSeen = SyncBox<Int>(0)
        let generatedSeen = SyncBox<Int>(0)

        let probe = FuzzPlugin<Int>(id: "observer_probe", handleSync: { event in
            switch event {
            case let .iteration(ctx):
                if ctx.poolParentID != nil {
                    mutatedSeen.update { $0 += 1 }
                    if mutatedSeen.value >= 32, generatedSeen.value >= 2 {
                        return [.stop(.init(reason: .custom("observed_enough")))]
                    }
                } else if !ctx.fromMutationQueue {
                    generatedSeen.update { $0 += 1 }
                }
                return []
            }
        })

        let result = try await fuzz(
            duration: .seconds(10),
            persistence: .ephemeral,
            parallelism: 1,
            plugins: { [probe] }
        ) { (input: Int) in
            blackHole(input)
        }

        // Pool-driven mutants executed, fresh generation kept mixing in, and
        // the corpus grew — all without corpusMutation on the bus.
        #expect(mutatedSeen.value >= 32)
        #expect(generatedSeen.value >= 2)
        #expect(result.corpus.count > 0)
    }

    @Test("Scheduler bursts respect the configured burst length")
    func configuredBurstLength() async throws {
        let runs = SyncBox<[Int?]>([])

        let probe = FuzzPlugin<Int>(id: "burst_probe", handleSync: { event in
            switch event {
            case let .iteration(ctx):
                runs.update { $0.append(ctx.poolParentID) }
                if runs.value.count >= 200 {
                    return [.stop(.init(reason: .custom("observed_enough")))]
                }
                return []
            }
        })

        _ = try await fuzz(
            duration: .seconds(10),
            persistence: .ephemeral,
            scheduler: .weightedPool(burstLength: 4),
            parallelism: 1,
            plugins: { [probe] }
        ) { (input: Int) in
            blackHole(input)
        }

        // Maximal runs of consecutive same-parent iterations never exceed the
        // configured burst (a fresh generation or redraw breaks every run).
        var longest = 0
        var current = 0
        var prev: Int? = nil
        for parent in runs.value {
            if let parent, parent == prev {
                current += 1
            } else {
                current = parent != nil ? 1 : 0
            }
            prev = parent
            longest = max(longest, current)
        }
        #expect(longest <= 4)
        #expect(longest >= 1, "pool mutants should appear at all")
    }
}
