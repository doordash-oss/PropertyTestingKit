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

//  The decoupling proof: a scheduler that owns NO pool. It always produces a
//  freshly generated input and retains nothing. This is unexpressible on the
//  old seam (which forced every scheduler into an indexed retained-input pool
//  via `.mutate(id:)` / `RetainedEntry.id`); that it drives the engine
//  end-to-end is exactly the smell this refactor removed.
//

import Testing
@testable import PropertyTestingKit
@testable import FuzzCore

/// A scheduler with no working set: every `next()` generates fresh, `observe`
/// retains nothing, and it requires no probes.
private struct GenerativeOnlyFactory: SchedulerFactory {
    func makeScheduler<each Input: Codable & Sendable>(
        mutators: repeat Mutator<each Input>
    ) -> AnyScheduler<repeat each Input> {
        let mutators = (repeat each mutators)
        return AnyScheduler(
            requiredProbes: [],
            next: {
                var rng = FastRNG()
                return ScheduledInput(
                    input: generateInput(rng: &rng, mutators: repeat each mutators),
                    poolParentID: nil
                )
            },
            observe: { _, _, _ in nil }
        )
    }
}

@Suite("Pool-less scheduler")
struct PoollessSchedulerTests {

    /// Stop a run once the bus has observed `count` iterations — deterministic
    /// and load-independent, unlike a wall-clock budget (a busy CI core under
    /// the full parallel suite can run zero iterations in 0.3s if probe setup
    /// alone exhausts the budget, which is what made this test flaky).
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

    @Test("A scheduler with no pool drives the engine end-to-end")
    func poollessSchedulerRuns() async throws {
        // `fuzz` accepts any `SchedulerFactory` directly — a userspace scheduler
        // needs no `MutationScheduler` wrapper and no pool. A generous wall-clock
        // ceiling plus a count-based stop makes "it ran inputs" deterministic
        // regardless of how loaded the machine is.
        let result = try await fuzz(
            duration: .seconds(60),
            persistence: .ephemeral,
            scheduler: GenerativeOnlyFactory(),
            parallelism: 1,
            plugins: { [self.stopAfter(50)] }
        ) { (input: Int) in
            blackHole(input)
        }

        // It ran inputs (the engine never assumed a pool) and retained none.
        #expect(result.stats.totalInputs > 0)
        #expect(result.corpus.count == 0)
    }
}
