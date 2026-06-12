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
//  information gain (yield), lineage-attributed via pool entry IDs, flushed
//  as weights at draw time. Same scoring math the old `energyMutation` bus
//  plugin used (pinned in EnergyMutationTests); these tests pin the POLICY
//  behavior — attribution, decay, and selection — on the pool's event stream.
//

import Testing
@testable import PropertyTestingKit

@Suite("Entropic pool policy")
struct EntropicPolicyTests {

    /// Draw-heavy core: burstLength 1, no focus-on-insert, so every cycle is
    /// draw → mutate → fresh and the weight distribution is observable.
    private func makeCore(
        admission: PoolAdmission = .everyDiscovery,
        policy: EntropicWeightPolicy = EntropicWeightPolicy()
    ) -> WeightedPoolCore {
        WeightedPoolCore(
            admission: admission, policies: [policy],
            burstLength: 1, focusOnInsert: false)
    }

    private func accept(_ core: WeightedPoolCore, edges: [UInt32], parent: Int? = nil) -> Int? {
        let source: PoolIterationSource = parent.map { .pool(parent: $0) } ?? .generated
        return core.observe(PoolIterationOutcome(
            source: source, newCoverage: SparseCoverage(indices: edges)))
    }

    private func miss(_ core: WeightedPoolCore, parent: Int? = nil) {
        let source: PoolIterationSource = parent.map { .pool(parent: $0) } ?? .generated
        _ = core.observe(PoolIterationOutcome(source: source, newCoverage: nil))
    }

    /// Run draw cycles, tallying which entry each draw picks.
    private func tallyDraws(_ core: WeightedPoolCore, cycles: Int) -> [Int: Int] {
        var picks: [Int: Int] = [:]
        for _ in 0..<cycles {
            if case let .mutate(id) = core.next() {
                picks[id, default: 0] += 1
                miss(core, parent: id)
            } else {
                miss(core)
            }
        }
        return picks
    }

    @Test("Weighted selection reaches every entry")
    func selectionReachesEveryEntry() {
        let core = makeCore()
        #expect(accept(core, edges: [10]) == 0)
        #expect(accept(core, edges: [20]) == 1)
        let picks = tallyDraws(core, cycles: 200)
        #expect(picks[0, default: 0] > 0)
        #expect(picks[1, default: 0] > 0)
    }

    @Test("A seed worn down by fruitless mutant executions loses energy")
    func unproductiveExecutionsDecayParent() {
        let core = makeCore()
        #expect(accept(core, edges: [10]) == 0)                  // A
        for _ in 0..<50 { miss(core, parent: 0) }                // 50 fruitless mutants
        #expect(accept(core, edges: [20]) == 1)                  // B, fresh

        let picks = tallyDraws(core, cycles: 300)
        #expect(picks[1, default: 0] > picks[0, default: 0],
                "fresh B must out-draw A after A's 50 fruitless executions")
    }

    @Test("Rejected discoveries still credit the parent's yield")
    func rejectedDiscoveryCreditsParent() {
        // Under feature-ownership admission, a mutant that re-witnesses
        // already-owned features is NOT admitted — but the discovery is still
        // information about its parent's neighborhood, so the parent's yield
        // grows and its energy rises.
        let core = makeCore(admission: .featureOwnership)
        #expect(accept(core, edges: [10, 11]) == 0)              // A owns {10,11}
        #expect(accept(core, edges: [20]) == 1)                  // B owns {20}

        // Five of A's mutants re-elicit A's rare features; all rejected
        // (equal coverage size ties never steal), all credit A's yield.
        for _ in 0..<5 {
            #expect(accept(core, edges: [10, 11], parent: 0) == nil)
        }

        let picks = tallyDraws(core, cycles: 300)
        #expect(picks[0, default: 0] > picks[1, default: 0],
                "a seed whose mutants keep eliciting rare features carries more information")
    }

    @Test("Evicted entries stop receiving weight but their stats survive for lineage")
    func evictionStopsWeights() {
        let core = makeCore(admission: .featureOwnership)
        #expect(accept(core, edges: [1, 2]) == 0)                // A owns {1,2}, size 2
        #expect(accept(core, edges: [9]) == 1)                   // B
        #expect(accept(core, edges: [1]) == 2)                   // steals {1}
        #expect(accept(core, edges: [2]) == 3)                   // steals {2} -> A evicted

        let picks = tallyDraws(core, cycles: 200)
        #expect(picks[0] == nil, "evicted A is never drawn")
        // Attribution to the dead parent must not crash; its mutants may
        // still be in flight.
        miss(core, parent: 0)
    }

    @Test("End-to-end: entropic advisor composes with culling in a real run")
    func integrationSmoke() async throws {
        let iterations = SyncBox<Int>(0)
        let probe = FuzzPlugin<Int>(id: "iteration_counter", handleSync: { event in
            switch event {
            case .iteration:
                iterations.update { $0 += 1 }
                return iterations.value >= 500
                    ? [.stop(.init(reason: .custom("observed_enough")))] : []
            }
        })

        let result = try await fuzz(
            duration: .seconds(10),
            persistence: .ephemeral,
            scheduler: .weightedPool(
                admission: .featureOwnership,
                policies: { [.entropic()] }
            ),
            parallelism: 1,
            plugins: { [probe] }
        ) { (input: Int) in
            blackHole(input)
        }
        #expect(iterations.value >= 500)
        #expect(result.corpus.count > 0)
    }
}
