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

//  The Entropic energy scheduler as a pool weight advisor: rare-feature
//  information gain (yield), lineage-attributed via pool entry IDs, flushed as
//  weights at draw time.
//
//  These tests drive the advisor DIRECTLY off the pool's event stream and
//  assert on the weights it flushes — no RNG, no random draws. The earlier
//  draw-tally tests asserted strict inequalities on weighted-RANDOM draws from
//  an unseedable `FastRNG`; because the entropic weights involved are close,
//  those assertions were a coin flip (~35% flake). Asserting on the computed
//  weights instead is both deterministic and a more precise check of the
//  advisor's actual contract. Each comparison isolates ONE variable (yield vs
//  abundance) so the asserted direction is unambiguous under the scoring math.
//

import Testing
@testable import PropertyTestingKit

@Suite("Entropic pool policy")
struct EntropicPolicyTests {

    // MARK: - Event-stream drivers (mirror what WeightedPoolCore sends)

    private func insert(_ p: EntropicWeightPolicy, id: Int, edges: [UInt32]) {
        // The pool emits the entry's RESOLVED features; with no strategy
        // vocabulary that's the widened covered edges.
        _ = p.handle(event: .inserted(
            id: id, coverage: SparseCoverage(indices: edges), features: edges.map(UInt64.init)))
    }

    /// A pool mutant of `parent` that elicited coverage (admitted or rejected —
    /// either way the discovery credits the parent's yield).
    private func discovery(_ p: EntropicWeightPolicy, parent: Int, edges: [UInt32]) {
        _ = p.handle(event: .iteration(PoolIterationOutcome(
            source: .pool(parent: parent), newCoverage: SparseCoverage(indices: edges))))
    }

    /// A pool mutant of `parent` that elicited nothing (a fruitless execution).
    private func fruitless(_ p: EntropicWeightPolicy, parent: Int) {
        _ = p.handle(event: .iteration(PoolIterationOutcome(
            source: .pool(parent: parent), newCoverage: nil)))
    }

    private func remove(_ p: EntropicWeightPolicy, id: Int) {
        _ = p.handle(event: .removed(id: id))
    }

    /// The weights the advisor flushes for the current corpus at a draw.
    private func weights(_ p: EntropicWeightPolicy) -> [Int: Double] {
        var w: [Int: Double] = [:]
        for action in p.handle(event: .willDraw) {
            if case let .setWeight(id, weight) = action { w[id] = weight }
        }
        return w
    }

    // MARK: - Weighting behavior (deterministic — asserts on emitted weights)

    @Test("Every live entry receives a positive weight")
    func everyLiveEntryWeighted() throws {
        let p = EntropicWeightPolicy()
        insert(p, id: 0, edges: [10])
        insert(p, id: 1, edges: [20])

        let w = weights(p)
        #expect(try #require(w[0]) > 0)
        #expect(try #require(w[1]) > 0)
    }

    @Test("Fruitless executions decay a seed's weight below a fresh peer")
    func fruitlessExecutionsDecay() throws {
        // A and B are symmetric (one rare feature each); only A is worn down.
        // Isolating EXECUTIONS (equal yield) makes the abundance decay the only
        // difference, so the direction is unambiguous.
        let p = EntropicWeightPolicy()
        insert(p, id: 0, edges: [10])     // A
        insert(p, id: 1, edges: [20])     // B
        for _ in 0..<50 { fruitless(p, parent: 0) }

        let w = weights(p)
        #expect(try #require(w[0]) < #require(w[1]),
                "50 fruitless executions must decay A below fresh B")
    }

    @Test("Rejected discoveries credit the parent's yield, raising it above an equally-mutated fruitless peer")
    func rejectedDiscoveriesCreditYield() throws {
        // Both seeds get the SAME number of executions (5), so the abundance
        // term is equal; the only difference is that A's mutants kept eliciting
        // a rare feature (yield credited) while B's were fruitless. Isolating
        // YIELD makes the direction unambiguous: A must out-weigh B.
        let p = EntropicWeightPolicy()
        insert(p, id: 0, edges: [10])     // A owns rare feature 10
        insert(p, id: 1, edges: [20])     // B owns rare feature 20
        for _ in 0..<5 { discovery(p, parent: 0, edges: [10]) }   // A's mutants re-elicit 10
        for _ in 0..<5 { fruitless(p, parent: 1) }                // B's mutants yield nothing

        let w = weights(p)
        #expect(try #require(w[0]) > #require(w[1]),
                "a seed whose mutants keep eliciting rare features carries more information")
    }

    @Test("Removed entries receive no weight; attributing to a dead parent does not crash")
    func removedEntriesGetNoWeight() throws {
        let p = EntropicWeightPolicy()
        insert(p, id: 0, edges: [1, 2])
        insert(p, id: 1, edges: [9])
        remove(p, id: 0)

        let w = weights(p)
        #expect(w[0] == nil, "evicted entry is never weighted")
        #expect(w[1] != nil)

        // Mutants of the dead parent may still be in flight: attribution must
        // not crash and must not resurrect the entry's weight.
        fruitless(p, parent: 0)
        discovery(p, parent: 0, edges: [1, 2])
        #expect(weights(p)[0] == nil)
    }

    @Test("An idle draw — no membership or coverage change — flushes no weight updates")
    func idleDrawEmitsNothing() {
        // The advisor recomputes the corpus distribution on membership/coverage
        // changes (libFuzzer's batched update), not on every draw. With no
        // change since the last flush, `.willDraw` must produce no churn.
        let p = EntropicWeightPolicy()
        insert(p, id: 0, edges: [10])
        _ = p.handle(event: .willDraw)            // first flush after the insert

        let second = p.handle(event: .willDraw)   // nothing changed since
        #expect(second.isEmpty, "no membership/coverage change ⇒ no weight churn")
    }

    // MARK: - End-to-end composition

    @Test("End-to-end: entropic advisor composes with the pool in a real run", .timeLimit(.minutes(1)))
    func integrationSmoke() async throws {
        let iterations = SyncBox<Int>(0)
        let probe = FuzzPlugin<Int>(id: "iteration_counter", handleSync: { event in
            switch event {
            case .iteration:
                iterations.update { $0 += 1 }
                return iterations.value >= 300
                    ? [.stop(.init(reason: .custom("observed_enough")))] : []
            }
        })

        let result = try await fuzz(
            duration: .seconds(10),
            persistence: .ephemeral,
            scheduler: MutationScheduler.weightedPool(
                admission: .everyDiscovery,
                policies: { [.entropic()] }
            ),
            parallelism: 1,
            plugins: { [probe] }
        ) { (input: Int) in
            // Input-dependent branches produce real, non-empty coverage, so the
            // corpus is reliably populated even under parallel load — unlike an
            // empty body, whose zero-edge runs are admission-rejected.
            if input % 2 == 0 {
                blackHole(input &* 3)
            } else {
                blackHole(input &+ 1)
            }
        }

        #expect(result.corpus.count > 0, "the advised pool must retain interesting inputs")
    }
}
