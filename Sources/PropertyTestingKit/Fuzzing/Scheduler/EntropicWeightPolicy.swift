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
/// - `.removed` entries stop receiving weights and have their per-entry yield
///   freed (a dead entry is never drawn again); their execution count survives
///   so mutants of a dead parent still attribute without resurrecting it.
/// - `.willDraw` flushes weights — but only when the corpus distribution
///   actually changed since the last flush (an insertion, an eviction, or a
///   new discovery). Idle draws cost nothing. This mirrors libFuzzer, which
///   recomputes its corpus distribution in batches on corpus change rather
///   than on every mutation step; between discoveries the abundance decay is
///   deferred to the next distribution update.
///
/// Rarity caching: an entry's rarity terms are recomputed only when they can
/// have moved — a full pass when an insertion shifts the global frequencies
/// (which can re-classify any entry's features), otherwise only the entries
/// whose own yield grew. The scoring math is `entropicWeightCombining` & co.,
/// pinned by characterization tests against hand-computed vectors.
public final class EntropicWeightPolicy: PoolPlugin {
    private let rareFeatureThreshold: Int
    private let maxMutationFactor: Int

    /// Per-entry rare-feature observation counts, keyed by pool entry ID. Freed
    /// on eviction (a dead entry is never drawn, so its yield is dead weight).
    private var entryYield: [Int: [UInt64: Int]] = [:]
    /// Per-entry executed-mutant count, keyed by ID. Retained past eviction so
    /// in-flight mutants of a dead parent still attribute (and `totalExecutions`
    /// stays consistent) without resurrecting the entry.
    private var entryExecutions: [Int: Int] = [:]
    /// Cached rarity terms per live entry, keyed by ID (freed on eviction).
    private var entryRarity: [Int: EntropicRarityTerms] = [:]
    /// Live (drawable) entry IDs — authoritative membership for weight emission
    /// and the corpus-size term.
    private var liveIDs: Set<Int> = []

    private var globalFeatureFreqs: [UInt64: Int] = [:]
    private var totalRareFeatures = 0
    private var totalExecutions = 0

    /// Entries whose YIELD changed since the last rarity recompute; a per-entry
    /// recompute suffices because their global frequencies did not move.
    private var dirtyRarity: Set<Int> = []
    /// Set when an insertion changed `globalFeatureFreqs`, which can shift the
    /// rare/abundant classification of EVERY entry — forcing a full recompute.
    private var rarityAllStale = false
    /// Set when the corpus distribution changed (insert / removal / new
    /// coverage) and must be re-flushed as weights at the next draw. Cleared
    /// after a flush, so an idle `.willDraw` (no change since) emits nothing.
    private var distributionStale = false

    public init(rareFeatureThreshold: Int = 3, maxMutationFactor: Int = 20) {
        self.rareFeatureThreshold = rareFeatureThreshold
        self.maxMutationFactor = maxMutationFactor
    }

    public func handle(event: PoolEvent) -> [PoolAction] {
        switch event {
        case let .iteration(outcome):
            guard case let .pool(parent) = outcome.source,
                  let executions = entryExecutions[parent] else { return [] }
            entryExecutions[parent] = executions + 1
            totalExecutions += 1
            // Crediting a dead parent's yield is pointless (it is never drawn)
            // and would re-grow the dictionary freed on eviction, so only live
            // parents accrue yield. Account in the run's RESOLVED features (the
            // strategy's vocabulary, or widened edges) — the same vocabulary the
            // ledger owns over.
            if outcome.newCoverage != nil, liveIDs.contains(parent) {
                for feature in outcome.resolvedFeatures {
                    entryYield[parent, default: [:]][feature, default: 0] += 1
                }
                dirtyRarity.insert(parent)
                distributionStale = true
            }
            return []

        case let .inserted(id, _, features):
            var yield: [UInt64: Int] = [:]
            for feature in features {
                yield[feature] = 1
                globalFeatureFreqs[feature, default: 0] += 1
            }
            entryYield[id] = yield
            entryExecutions[id] = 0
            entryRarity[id] = EntropicRarityTerms(energy: 0, sumIncidence: 0, coveredRare: 0)
            liveIDs.insert(id)
            // Global frequencies moved → any entry's rarity may have shifted.
            rarityAllStale = true
            distributionStale = true
            return []

        case let .removed(id):
            liveIDs.remove(id)
            // Free the heavy per-entry payload; keep the scalar execution count
            // so in-flight mutants of this dead parent still attribute.
            entryYield[id] = nil
            entryRarity[id] = nil
            dirtyRarity.remove(id)
            distributionStale = true
            return []

        case .willDraw:
            guard distributionStale, !liveIDs.isEmpty else { return [] }
            refreshRarityIfNeeded()

            let corpusSize = liveIDs.count
            var actions: [PoolAction] = []
            actions.reserveCapacity(corpusSize)
            for id in liveIDs {
                let cache = entryRarity[id]
                    ?? EntropicRarityTerms(energy: 0, sumIncidence: 0, coveredRare: 0)
                actions.append(.setWeight(id: id, entropicWeightCombining(
                    cache: cache,
                    mutations: entryExecutions[id] ?? 0,
                    totalRareFeatures: totalRareFeatures,
                    totalMutations: totalExecutions,
                    corpusSize: corpusSize,
                    maxMutationFactor: maxMutationFactor
                )))
            }
            distributionStale = false
            return actions
        }
    }

    /// Recompute cached rarity terms — all live entries when global frequencies
    /// moved (an insertion can re-classify any entry's features), otherwise only
    /// the entries whose own yield changed.
    private func refreshRarityIfNeeded() {
        if rarityAllStale {
            totalRareFeatures = globalFeatureFreqs.values
                .filter { $0 <= rareFeatureThreshold }.count
            for id in liveIDs {
                entryRarity[id] = entropicYieldRarityTerms(
                    yield: entryYield[id] ?? [:],
                    globalFreqs: globalFeatureFreqs,
                    rareFeatureThreshold: rareFeatureThreshold)
            }
            rarityAllStale = false
            dirtyRarity.removeAll()
        } else if !dirtyRarity.isEmpty {
            for id in dirtyRarity where liveIDs.contains(id) {
                entryRarity[id] = entropicYieldRarityTerms(
                    yield: entryYield[id] ?? [:],
                    globalFreqs: globalFeatureFreqs,
                    rareFeatureThreshold: rareFeatureThreshold)
            }
            dirtyRarity.removeAll()
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
