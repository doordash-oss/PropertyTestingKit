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

//  Tests for pathTrie coverage strategy integration with the fuzz engine.
//

import Testing
import Foundation
import SanCovHooks
@testable import PropertyTestingKit

@Suite("PathTrie Strategy")
struct PathTrieStrategyTests {

    @Test("First iteration trie path is not empty")
    func firstIterationTriePathNotEmpty() {
        let strategy: CoverageEvaluator<Int> = CoverageStrategy<Int>.pathTrie.makeEvaluator()
        let context = SanCovCounters.beginMeasurement()
        // The context co-owns the strategy's observer (and so its trie) — no
        // lifetime pinning needed even though edges dispatch until the end.
        defer { SanCovCounters.endMeasurement(context) }
        let coverageClient = CoverageCountersClient.liveValue
        let corpus = Corpus<Int>()

        // Call setup BEFORE recording edges — this attaches the trie
        strategy.setup?(context)

        // Simulate edges being hit during test execution
        var g0: UInt32 = 0
        var g1: UInt32 = 1
        var g2: UInt32 = 2
        sancov_dispatch_edge(&g0)
        sancov_dispatch_edge(&g1)
        sancov_dispatch_edge(&g2)

        // Evaluate the strategy
        let didAdd = strategy.evaluate(42, nil, context, coverageClient, corpus) != nil

        #expect(didAdd, "First iteration should be interesting")
        #expect(corpus.entries.count == 1, "Should have one corpus entry")

        // Second iteration with the SAME edges should be a duplicate.
        // If the trie recorded the path on iteration 1, this is not novel.
        coverageClient.resetCoverage(context)
        g0 = 0; g1 = 1; g2 = 2
        sancov_dispatch_edge(&g0)
        sancov_dispatch_edge(&g1)
        sancov_dispatch_edge(&g2)

        let didAddSecond = strategy.evaluate(42, nil, context, coverageClient, corpus) != nil

        #expect(
            !didAddSecond,
            "Same path should be duplicate — trie missed first iteration if this fails"
        )
    }
}
