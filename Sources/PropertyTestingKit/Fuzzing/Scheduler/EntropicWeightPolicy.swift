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

//  libFuzzer's Entropic energy scheduler as a pool weight advisor.
//

/// Weights pool entries by information gain: a seed whose mutants keep
/// eliciting globally-rare coverage features carries high energy and gets
/// drawn more; a seed worn down by fruitless executions decays (abundance
/// term) and is eventually zeroed by the over-fuzzing guard.
///
/// Ports libFuzzer's Entropic schedule onto the pool's event stream:
/// - `.iteration` with a pool parent attributes the execution, and any
///   discovery's features credit the parent's *yield* — including
///   discoveries the admission rejects (a rejected mutant is still
///   information about its parent's neighborhood).
/// - `.inserted` registers the entry (its own coverage seeds its yield) and
///   updates global feature frequencies — rarity is "few pool entries
///   exhibit it".
/// - `.willDraw` flushes weights: rarity terms are cached and recomputed
///   only when acceptance changed them; the abundance term varies per draw.
/// - `.removed` entries stop receiving weights; their stats stay (mutants
///   of a dead parent may still be in flight and attribute correctly).
///
/// The scoring math is `entropicWeightCombining` & co., pinned by
/// characterization tests against hand-computed vectors.
public final class EntropicWeightPolicy: PoolPlugin {
    private let rareFeatureThreshold: Int
    private let maxMutationFactor: Int

    /// Per-entry rare-feature observation counts, index == pool entry ID.
    private var entryYield: [[UInt32: Int]] = []
    /// Per-entry executed-mutant count, attributed via `.pool(parent:)`.
    private var entryExecutions: [Int] = []
    /// Cached rarity terms (refreshed when `rarityStale`).
    private var entryRarity: [EntropicRarityTerms] = []
    private var globalFeatureFreqs: [UInt32: Int] = [:]
    private var totalRareFeatures = 0
    private var totalExecutions = 0
    private var rarityStale = false
    private var removed: Set<Int> = []

    public init(rareFeatureThreshold: Int = 3, maxMutationFactor: Int = 20) {
        self.rareFeatureThreshold = rareFeatureThreshold
        self.maxMutationFactor = maxMutationFactor
    }

    public func handle(event: PoolEvent) -> [PoolAction] {
        switch event {
        case let .iteration(outcome):
            guard case let .pool(parent) = outcome.source,
                  entryExecutions.indices.contains(parent) else { return [] }
            entryExecutions[parent] += 1
            totalExecutions += 1
            if let coverage = outcome.newCoverage {
                for feature in coverage.indices {
                    entryYield[parent][feature, default: 0] += 1
                }
                rarityStale = true
            }
            return []

        case let .inserted(id, coverage):
            // IDs are sequential by the owner's contract; the only way to
            // see a gap would be another inserter, which the admission role
            // precludes.
            assert(id == entryYield.count, "pool entry IDs must be sequential")
            for feature in coverage.indices {
                globalFeatureFreqs[feature, default: 0] += 1
            }
            entryYield.append(Dictionary(coverage.indices.map { ($0, 1) },
                                         uniquingKeysWith: +))
            entryExecutions.append(0)
            entryRarity.append(EntropicRarityTerms(energy: 0, sumIncidence: 0, coveredRare: 0))
            rarityStale = true
            return []

        case let .removed(id):
            removed.insert(id)
            return []

        case .willDraw:
            guard !entryYield.isEmpty else { return [] }
            if rarityStale {
                totalRareFeatures = globalFeatureFreqs.values
                    .filter { $0 <= rareFeatureThreshold }.count
                entryRarity = entryYield.map {
                    entropicYieldRarityTerms(
                        yield: $0,
                        globalFreqs: globalFeatureFreqs,
                        rareFeatureThreshold: rareFeatureThreshold)
                }
                rarityStale = false
            }
            var actions: [PoolAction] = []
            actions.reserveCapacity(entryYield.count - removed.count)
            for id in 0..<entryYield.count where !removed.contains(id) {
                actions.append(.setWeight(id: id, entropicWeightCombining(
                    cache: entryRarity[id],
                    mutations: entryExecutions[id],
                    totalRareFeatures: totalRareFeatures,
                    totalMutations: totalExecutions,
                    corpusSize: entryYield.count - removed.count,
                    maxMutationFactor: maxMutationFactor
                )))
            }
            return actions
        }
    }
}

extension PoolPlugin where Self == EntropicWeightPolicy {
    /// libFuzzer's Entropic energy schedule: weight pool entries by
    /// rare-feature information gain, with abundance decay and an
    /// over-fuzzing guard.
    public static func entropic(
        rareFeatureThreshold: Int = 3,
        maxMutationFactor: Int = 20
    ) -> EntropicWeightPolicy {
        EntropicWeightPolicy(
            rareFeatureThreshold: rareFeatureThreshold,
            maxMutationFactor: maxMutationFactor)
    }
}
