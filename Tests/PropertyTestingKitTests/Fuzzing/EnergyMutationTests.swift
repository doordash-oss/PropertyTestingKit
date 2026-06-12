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

//  Characterization tests for the energy-based mutation scheduler
//  (`FuzzPlugin.energyMutation`): the entropic weight math pinned against
//  hand-computed vectors, the over-fuzzing guard, and the plugin's
//  accept-burst / drain-selection behavior.
//

import Testing
@testable import PropertyTestingKit

@Suite("Energy mutation scheduler")
struct EnergyMutationTests {

    // MARK: - entropicWeight vectors (hand-computed)

    @Test("Weight of an entry covering a rare feature")
    func weightWithRareFeatureCovered() {
        // features 1 (freq 1, rare) and 2 (freq 5, common); 1 rare feature total.
        // energy = -2*ln2, sumIncidence = 2 (rare) + 1 (abundance) = 3
        // weight = 2^(energy/3 + ln 3)
        let w = entropicWeight(
            features: [1, 2], mutations: 0,
            globalFreqs: [1: 1, 2: 5], totalRareFeatures: 1,
            totalMutations: 0, corpusSize: 1,
            rareFeatureThreshold: 3, maxMutationFactor: 20)
        #expect(abs(w - 1.5545684782022196) < 1e-9)
    }

    @Test("Weight is uniform 1.0 when nothing rare exists")
    func weightUniformWithoutRareFeatures() {
        // Only a common feature, no rare features anywhere: energy 0,
        // sumIncidence = abundance 1 -> 2^(0 + ln 1) = ... sumIncidence is 1,
        // so weight = 2^(0/1 + 0) = 1.
        let w = entropicWeight(
            features: [7], mutations: 0,
            globalFreqs: [7: 10], totalRareFeatures: 0,
            totalMutations: 0, corpusSize: 1,
            rareFeatureThreshold: 3, maxMutationFactor: 20)
        #expect(w == 1.0)
    }

    @Test("CHARACTERIZATION: not covering the rare feature can outweigh covering it")
    func uncoveredRareOutweighsCovered() {
        // Same corpus state as the rare-covered vector, but this entry covers
        // only the common feature. Its energy is 0 and its sumIncidence is
        // 1 (uncovered rare) + 1 (abundance) = 2 -> weight 2^(ln 2) ~ 1.617,
        // ABOVE the rare-feature owner's 1.555. Pinned as-is: the static
        // adaptation of Entropic does not generally favor rare-edge owners.
        let w = entropicWeight(
            features: [7], mutations: 0,
            globalFreqs: [7: 10], totalRareFeatures: 1,
            totalMutations: 0, corpusSize: 1,
            rareFeatureThreshold: 3, maxMutationFactor: 20)
        #expect(abs(w - 1.6168066722416747) < 1e-9)
        #expect(w > 1.5545684782022196, "documented inversion vs the rare-feature owner")
    }

    @Test("Abundance term decays an over-mutated entry's weight")
    func abundanceDecaysWeight() {
        let fresh = entropicWeight(
            features: [1, 2], mutations: 0,
            globalFreqs: [1: 1, 2: 5], totalRareFeatures: 1,
            totalMutations: 10, corpusSize: 2,
            rareFeatureThreshold: 3, maxMutationFactor: 20)
        let worn = entropicWeight(
            features: [1, 2], mutations: 9,
            globalFreqs: [1: 1, 2: 5], totalRareFeatures: 1,
            totalMutations: 10, corpusSize: 2,
            rareFeatureThreshold: 3, maxMutationFactor: 20)
        #expect(abs(worn - 1.3665717502522239) < 1e-9)
        #expect(worn < fresh)
    }

    @Test("Over-fuzzing guard zeroes far-beyond-average entries")
    func overFuzzGuardZeroes() {
        // avg = 100/2 = 50; 2000/20 = 100 > 50 -> zeroed.
        let w = entropicWeight(
            features: [1], mutations: 2000,
            globalFreqs: [1: 1], totalRareFeatures: 1,
            totalMutations: 100, corpusSize: 2,
            rareFeatureThreshold: 3, maxMutationFactor: 20)
        #expect(w == 0.0)
    }

    @Test("Over-fuzzing guard boundary is exclusive")
    func overFuzzGuardBoundary() {
        // avg = 50; 1000/20 = 50, not > 50 -> NOT zeroed.
        let w = entropicWeight(
            features: [1], mutations: 1000,
            globalFreqs: [1: 1], totalRareFeatures: 1,
            totalMutations: 100, corpusSize: 2,
            rareFeatureThreshold: 3, maxMutationFactor: 20)
        #expect(abs(w - 1.0100243271635463) < 1e-9)
    }

    // MARK: - Incremental (cached) weight equivalence

    /// The drain-time hot path combines per-entry rarity terms (computed at
    /// acceptance) with the abundance term in O(1). It must agree exactly
    /// with the reference formula for any configuration.
    @Test("Cached rarity terms + combine == reference entropicWeight")
    func cachedCombineMatchesReference() {
        var rng = FastRNG()
        for _ in 0..<500 {
            let featureCount = Int.random(in: 0...6, using: &rng)
            let features = (0..<featureCount).map { _ in UInt32.random(in: 0...9, using: &rng) }
            var freqs: [UInt32: Int] = [:]
            for f in 0...9 { freqs[UInt32(f)] = Int.random(in: 1...6, using: &rng) }
            let totalRare = freqs.values.filter { $0 <= 3 }.count
            let mutations = Int.random(in: 0...100, using: &rng)
            let totalMutations = Int.random(in: 0...200, using: &rng)
            let corpusSize = Int.random(in: 1...10, using: &rng)

            let reference = entropicWeight(
                features: features, mutations: mutations,
                globalFreqs: freqs, totalRareFeatures: totalRare,
                totalMutations: totalMutations, corpusSize: corpusSize,
                rareFeatureThreshold: 3, maxMutationFactor: 20)

            let cache = entropicRarityTerms(
                features: features, globalFreqs: freqs, rareFeatureThreshold: 3)
            let combined = entropicWeightCombining(
                cache: cache, mutations: mutations,
                totalRareFeatures: totalRare, totalMutations: totalMutations,
                corpusSize: corpusSize, maxMutationFactor: 20)

            #expect(abs(reference - combined) < 1e-12,
                    "split form must agree: features=\(features) m=\(mutations)")
        }
    }

    // MARK: - Plugin behavior

    private func iteration(
        _ input: Int, fromQueue: Bool, queueCount: Int = 0, coverage: [UInt32]? = nil,
        parentID: Int? = nil
    ) -> SyncPluginEvent<Int> {
        .iteration(SyncPluginEvent<Int>.IterationContext(
            input: input,
            fromMutationQueue: fromQueue,
            queueCount: queueCount,
            newCoverage: coverage.map { SparseCoverage(indices: $0) },
            parentID: parentID
        ))
    }

    @Test("New coverage triggers an immediate mutation burst of that input")
    func acceptBurst() {
        let plugin: FuzzPlugin<Int> = .energyMutation()
        let actions = plugin.handleSync(iteration(42, fromQueue: false, coverage: [1, 2]))
        #expect(actions.count == 1)
        guard case let .selectForMutation(sel) = actions.first else {
            Issue.record("expected selectForMutation, got \(actions)")
            return
        }
        #expect(sel.input == 42)
    }

    @Test("Drain with an empty corpus schedules nothing")
    func drainWithoutEntries() {
        let plugin: FuzzPlugin<Int> = .energyMutation()
        let actions = plugin.handleSync(iteration(1, fromQueue: false))
        #expect(actions.isEmpty)
    }

    @Test("Queue-sourced iterations without new coverage schedule nothing")
    func midQueueNoAction() {
        let plugin: FuzzPlugin<Int> = .energyMutation()
        _ = plugin.handleSync(iteration(42, fromQueue: false, coverage: [1]))
        let actions = plugin.handleSync(iteration(43, fromQueue: true, queueCount: 5))
        #expect(actions.isEmpty)
    }

    // MARK: - Discovery-attributed semantics (lineage-based Entropic)

    @Test("Accept burst tags the new entry's index as originID")
    func acceptBurstCarriesOriginID() {
        let plugin: FuzzPlugin<Int> = .energyMutation()
        let first = plugin.handleSync(iteration(1, fromQueue: false, coverage: [10]))
        guard case let .selectForMutation(s0) = first.first else {
            Issue.record("expected selectForMutation"); return
        }
        #expect(s0.originID == 0, "first entry is index 0")
        let second = plugin.handleSync(iteration(2, fromQueue: false, coverage: [20]))
        guard case let .selectForMutation(s1) = second.first else {
            Issue.record("expected selectForMutation"); return
        }
        #expect(s1.originID == 1, "second entry is index 1")
    }

    @Test("A seed worn down by unproductive mutant executions loses energy")
    func unproductiveExecutionsDecayParent() {
        let plugin: FuzzPlugin<Int> = .energyMutation()
        _ = plugin.handleSync(iteration(1, fromQueue: false, coverage: [10]))   // A = entry 0
        // 50 mutants of A execute and discover nothing.
        for _ in 0..<50 {
            _ = plugin.handleSync(iteration(99, fromQueue: true, queueCount: 1, parentID: 0))
        }
        _ = plugin.handleSync(iteration(2, fromQueue: false, coverage: [20]))   // B = entry 1, fresh
        // Expected weights: worn A ~ 1.1383, fresh B ~ 2.1415 -> P(B) ~ 0.65.
        var picks: [Int: Int] = [:]
        for _ in 0..<300 {
            let actions = plugin.handleSync(iteration(99, fromQueue: false))
            guard case let .selectForMutation(sel) = actions.first else {
                Issue.record("drain must schedule"); return
            }
            picks[sel.input, default: 0] += 1
        }
        #expect(picks[2, default: 0] > picks[1, default: 0],
                "fresh B must out-draw A after A's 50 fruitless mutant executions")
    }

    @Test("Yield rarity terms: counted observations, non-rare filtered")
    func yieldRarityTerms() {
        let t = entropicYieldRarityTerms(
            yield: [10: 3], globalFreqs: [10: 3], rareFeatureThreshold: 3)
        #expect(abs(t.energy - (-3.295836866004329)) < 1e-12)   // -3*ln 3
        #expect(t.sumIncidence == 3.0)
        #expect(t.coveredRare == 1)

        let filtered = entropicYieldRarityTerms(
            yield: [12: 5], globalFreqs: [12: 9], rareFeatureThreshold: 3)
        #expect(filtered.energy == 0 && filtered.sumIncidence == 0 && filtered.coveredRare == 0)
    }

    @Test("Repeated rare observations outweigh a single one at equal executions")
    func repeatedRareObservationsBoost() {
        let repeated = entropicWeightCombining(
            cache: entropicYieldRarityTerms(yield: [10: 3], globalFreqs: [10: 3], rareFeatureThreshold: 3),
            mutations: 10, totalRareFeatures: 2, totalMutations: 20,
            corpusSize: 2, maxMutationFactor: 20)
        let single = entropicWeightCombining(
            cache: entropicYieldRarityTerms(yield: [20: 1], globalFreqs: [20: 1], rareFeatureThreshold: 3),
            mutations: 10, totalRareFeatures: 2, totalMutations: 20,
            corpusSize: 2, maxMutationFactor: 20)
        #expect(abs(repeated - 1.6584910308010297) < 1e-9)
        #expect(abs(single - 1.4499076873304126) < 1e-9)
        #expect(repeated > single,
                "a seed whose mutants keep eliciting a rare feature carries more information")
    }

    @Test("Weighted-random drain selection reaches every entry")
    func drainSelectsAndRotates() {
        let plugin: FuzzPlugin<Int> = .energyMutation()
        _ = plugin.handleSync(iteration(1, fromQueue: false, coverage: [10]))
        _ = plugin.handleSync(iteration(2, fromQueue: false, coverage: [20]))

        var selected = Set<Int>()
        for _ in 0..<300 {
            let actions = plugin.handleSync(iteration(99, fromQueue: false))
            guard case let .selectForMutation(sel) = actions.first else {
                Issue.record("drain with entries must schedule a mutation")
                return
            }
            selected.insert(sel.input)
        }
        #expect(selected == [1, 2],
                "weighted-random selection must reach every entry")
    }
}
