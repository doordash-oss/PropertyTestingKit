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

//  cmp as a first-class, scheduler-vended signal — the payoff of the
//  Signal/Evaluator/Ledger decomposition. The scheduler carries the comparison
//  signal itself (`.boundaryDistance`): it vends the cmp-recording provider, and
//  `featureOwnership` culls over the comparison-distance axis through the same
//  `OwnershipLedger` as edges (the boundary evaluator is a peer of the edge
//  evaluator, not a bolt-on). The engine names no signal.
//
//  NOTE on scope: a *pure* cmp-only run (no edge axis at all, `.boundaryDistanceOnly`)
//  additionally needs (a) an instrumented comparison in the SUT — a bare stdlib
//  `Int ==` lowers to the uninstrumented standard library at -Onone, so it emits
//  no `trace_cmp` in-target — and (b) a corpus retention signature that isn't
//  `SparseCoverage` (edges). Both are the remaining Phase-3 work; this test pins
//  the part that is wired and green: cmp travels with the scheduler and shapes
//  the pool.
//

import Testing
@testable import PropertyTestingKit
@testable import FuzzCore

@Suite("Cmp signal scheduler")
struct CmpOnlySchedulerTests {

    /// Deterministic, load-independent stop (a busy core can run zero iterations
    /// in a small wall-clock budget — see PoollessSchedulerTests).
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

    @Test("A scheduler that vends the cmp signal drives the engine and culls over it")
    func cmpSignalSchedulerRuns() async throws {
        let result = try await fuzz(
            duration: .seconds(60),
            persistence: .ephemeral,
            // The scheduler carries the comparison signal: it vends the
            // cmp-recording provider and culls over the boundary-distance axis
            // (composed with edges) through the unified ownership ledger.
            scheduler: MutationScheduler.weightedPool(coverageStrategy: .boundaryDistance),
            parallelism: 1,
            plugins: { [self.stopAfter(200)] }
        ) { (input: Int) in
            if input % 2 == 0 {
                blackHole(input &* 3)
            } else {
                blackHole(input &+ 1)
            }
        }

        // The cmp-signal scheduler drove the engine and retained interesting
        // inputs through the same ledger edges use.
        #expect(result.stats.totalInputs > 0)
        #expect(result.corpus.count > 0, "the cmp-signal scheduler must drive retention")
    }
}
