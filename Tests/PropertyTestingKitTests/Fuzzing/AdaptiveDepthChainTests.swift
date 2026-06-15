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

//  Multi-generation mutation: a depth-d mutant chains the mutator d times
//  (mutate∘mutate∘…), and the per-seed depth is carried by the pool core via
//  the `.setMutationDepth` action so a policy can escalate depth on stale seeds.
//

import Testing
@testable import PropertyTestingKit

@Suite("Adaptive mutation depth (chaining + core plumbing)")
struct AdaptiveDepthChainTests {

    private final class Setter: PoolPlugin {
        let onInsert: (Int) -> [PoolAction]
        init(onInsert: @escaping (Int) -> [PoolAction]) { self.onInsert = onInsert }
        func handle(event: PoolEvent) -> [PoolAction] {
            if case let .inserted(id, _, _, _, _) = event { return onInsert(id) }
            return []
        }
    }

    @Test("chainMutate applies the mutator exactly depth times (min 1)")
    func chainAppliesDepthTimes() {
        let m = Mutator<String>(seeds: [""], mutate: { s, _ in s + "*" })
        var rng = FastRNG()
        #expect(chainMutate("", depth: 1, inputSize: 1, rng: &rng, mutators: m) == "*")
        #expect(chainMutate("", depth: 3, inputSize: 1, rng: &rng, mutators: m) == "***")
        // depth below 1 clamps to a single application (never a no-op pass-through).
        #expect(chainMutate("", depth: 0, inputSize: 1, rng: &rng, mutators: m) == "*")
    }

    @Test("core stores per-entry mutation depth; defaults to 1")
    func coreStoresDepth() {
        let setter = Setter { id in [.setMutationDepth(id: id, depth: 3)] }
        let core = WeightedPoolCore(
            admission: .everyDiscovery, policies: [setter],
            burstLength: 16, focusOnInsert: true)

        #expect(core.mutationDepth(for: 0) == 1)   // default before any entry exists
        _ = core.observe(PoolIterationOutcome(
            source: .generated, newCoverage: SparseCoverage(indices: [1])))
        #expect(core.mutationDepth(for: 0) == 3)   // policy escalated it
    }
}
