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

    /// Stop a run once the bus has observed `count` iterations — deterministic,
    /// not time-bound.
    private func stopAfter(_ count: Int) -> FuzzPlugin<Int> {
        let seen = SyncBox<Int>(0)
        return FuzzPlugin<Int>(id: "iteration_counter", handleSync: { event in
            switch event {
            case .iteration:
                seen.update { $0 += 1 }
                return seen.value >= count
                    ? [.stop(.init(reason: .custom("observed_enough")))]
                    : []
            }
        })
    }

    @Test("Default scheduler sustains the mutation loop without any bus plugins")
    func defaultSchedulerSustainsMutation() async throws {
        let result = try await fuzz(
            duration: .seconds(10),
            persistence: .ephemeral,
            parallelism: 1,
            plugins: { [self.stopAfter(200)] }
        ) { (input: Int) in
            blackHole(input)
        }

        // Pool-driven mutants executed AND fresh generation kept mixing in, and
        // the corpus grew — all without a bus mutation scheduler. Lineage is the
        // scheduler's own concern now, so we assert via the engine's stats.
        #expect(result.stats.mutations > 0)
        #expect(result.stats.generations > 0)
        #expect(result.corpus.count > 0)
    }

    @Test("Generation ratio 1 runs pure generation (no pool mutation)")
    func generationRatioAllGeneration() async throws {
        let result = try await fuzz(
            duration: .seconds(10),
            persistence: .ephemeral,
            scheduler: MutationScheduler.weightedPool(generationRatio: 1.0),
            parallelism: 1,
            plugins: { [self.stopAfter(200)] }
        ) { (input: Int) in
            blackHole(input)
        }

        // The scheduler honors its ratio knob: at 1.0 every step generates, so
        // no pool mutants are ever produced.
        #expect(result.stats.mutations == 0)
        #expect(result.stats.generations > 0)
    }
}
