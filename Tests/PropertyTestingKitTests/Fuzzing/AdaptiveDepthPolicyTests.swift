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

//  The productivity-weighted, adaptive-depth policy: a hit spikes the parent's
//  draw weight, a miss decays it, and sustained misses at a depth escalate that
//  seed's mutation depth while a productive depth stays shallow.
//

import Testing
@testable import PropertyTestingKit

@Suite("Adaptive-depth pool policy")
struct AdaptiveDepthPolicyTests {

    private func setWeight(_ actions: [PoolAction], id: Int) -> Double? {
        for a in actions { if case let .setWeight(i, w) = a, i == id { return w } }
        return nil
    }
    private func setDepth(_ actions: [PoolAction], id: Int) -> Int? {
        for a in actions { if case let .setMutationDepth(i, d) = a, i == id { return d } }
        return nil
    }

    private func insert(_ p: AdaptiveDepthPolicy, id: Int, parent: Int? = nil, claimed: Int = 1) {
        _ = p.handle(event: .inserted(
            id: id, coverage: SparseCoverage(indices: [UInt32(id) + 1]),
            features: [UInt64(id) + 1], parent: parent, claimed: claimed))
    }

    @Test("an owning mutant spikes its parent's weight by (1 + claimed)")
    func hitSpikesWeight() {
        let p = AdaptiveDepthPolicy(roll: { 50.0 })
        insert(p, id: 0)
        // A mutant of entry 0 finds new coverage...
        _ = p.handle(event: .iteration(PoolIterationOutcome(
            source: .pool(parent: 0), newCoverage: SparseCoverage(indices: [9]))))
        // ...and is admitted owning 2 features.
        insert(p, id: 1, parent: 0, claimed: 2)
        let actions = p.handle(event: .willDraw)   // flush the resolved mutant
        #expect(setWeight(actions, id: 0) == 3.0)  // 1.0 × (1 + 2)
    }

    @Test("a fruitless mutant decays its parent's weight by 0.95")
    func missDecaysWeight() {
        let p = AdaptiveDepthPolicy(roll: { 50.0 })
        insert(p, id: 0)
        _ = p.handle(event: .iteration(PoolIterationOutcome(
            source: .pool(parent: 0), newCoverage: nil)))
        let actions = p.handle(event: .willDraw)
        #expect(setWeight(actions, id: 0) == 0.95)
    }

    @Test("sustained misses at depth 1 escalate the seed's depth")
    func sustainedMissesEscalateDepth() {
        // Explicit alpha/ceiling=0.05/90 so the climbing score passes the fixed
        // roll of 50 within the loop (the tuned defaults 0.02/45 asymptote below
        // 50 by design); this test characterizes the escalate-on-miss behavior,
        // not the tuned magnitude.
        let p = AdaptiveDepthPolicy(alpha: 0.05, ceiling: 90.0, roll: { 50.0 })   // advances once a level's score passes 50
        insert(p, id: 0)
        var maxDepth = 1
        for _ in 0..<40 {
            _ = p.handle(event: .iteration(PoolIterationOutcome(
                source: .pool(parent: 0), newCoverage: nil)))
            let actions = p.handle(event: .willDraw)
            if let d = setDepth(actions, id: 0) { maxDepth = max(maxDepth, d) }
        }
        #expect(maxDepth >= 2)   // depth-1 neighborhood mined out → dig deeper
    }

    @Test("a productive depth stays shallow (hits anchor depth 1)")
    func productiveDepthStaysShallow() {
        let p = AdaptiveDepthPolicy(roll: { 50.0 })
        insert(p, id: 0)
        var escalated = false
        for i in 0..<40 {
            // Every mutant of entry 0 hits and is admitted (owns 1 new feature).
            _ = p.handle(event: .iteration(PoolIterationOutcome(
                source: .pool(parent: 0), newCoverage: SparseCoverage(indices: [UInt32(100 + i)]))))
            insert(p, id: 1 + i, parent: 0, claimed: 1)
            let actions = p.handle(event: .willDraw)
            if let d = setDepth(actions, id: 0), d > 1 { escalated = true }
        }
        #expect(!escalated)   // depth 1 keeps paying off → never escalates
    }
}
