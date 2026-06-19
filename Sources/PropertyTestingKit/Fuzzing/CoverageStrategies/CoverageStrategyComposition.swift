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

//  Composing coverage strategies: union several strategies into one so the
//  comparison channel can mix-and-match with edge strategies (and edge
//  strategies with each other).
//

extension CoverageStrategy {
    /// Compose strategies into one whose acceptance is their **union** — an
    /// input is interesting iff ANY substrategy finds it interesting — and whose
    /// pool vocabularies are the namespaced union of the substrategies'.
    ///
    /// Each substrategy keeps its own per-engine state: every substrategy's
    /// measurement hooks (`onEdge`/`onCompare`/`onReset`) run each iteration, and
    /// every substrategy's decision runs (none is short-circuited, so each
    /// updates its own novelty oracle) before the results are OR-ed. The
    /// published `features` are namespaced per substrategy (see
    /// `namespacedFeature`) so two strategies' raw vocabularies can never collide
    /// in the pool's shared ownership space; `boundaryDistances` are merged
    /// per-site by the closer (lower) value.
    ///
    /// The canonical use is mixing the comparison channel with an edge strategy,
    /// e.g. `.pathTrie.combined(with: .boundaryDistanceOnly)` — pair it with
    /// `PoolAdmission.featureOwnership`, which culls over both the
    /// (namespaced) features and the boundary distances.
    public static func compose(_ strategies: [CoverageStrategy]) -> CoverageStrategy {
        precondition(!strategies.isEmpty, "CoverageStrategy.compose requires at least one strategy")
        guard strategies.count > 1 else { return strategies[0] }
        return CoverageStrategy(makeEngine: {
            mergeEngines(strategies.map { $0.makeEngine() })
        })
    }

    /// Union this strategy with another (see ``compose(_:)``).
    public func combined(with other: CoverageStrategy) -> CoverageStrategy {
        .compose([self, other])
    }
}

/// Mix a feature value into a per-substrategy namespace so the same raw value
/// emitted by two different substrategies maps to two distinct features in the
/// pool's shared ownership space. A SplitMix64 finalizer on `value + salt·φ`:
/// deterministic, and effectively injective (cross-namespace collision is as
/// unlikely as the hash collisions the feature space already tolerates).
func namespacedFeature(_ value: UInt64, salt: UInt64) -> UInt64 {
    var x = value &+ (salt &* 0x9E37_79B9_7F4A_7C15)
    x = (x ^ (x >> 30)) &* 0xBF58_476D_1CE4_E5B9
    x = (x ^ (x >> 27)) &* 0x94D0_49BB_1331_11EB
    return x ^ (x >> 31)
}

/// Merge several per-engine bundles into one (see ``CoverageStrategy/compose(_:)``).
private func mergeEngines(_ engines: [CoverageEngine]) -> CoverageEngine {
    // Measurement: run every present hook. Capture only the non-nil ones so the
    // merged hook is nil (dormant, no per-event cost) when no substrategy uses
    // that channel — preserving e.g. "no cmp recorder attached" for edge-only
    // compositions.
    let edgeHooks = engines.compactMap(\.onEdge)
    let cmpHooks = engines.compactMap(\.onCompare)
    let resetHooks = engines.compactMap(\.onReset)

    let onEdge: (@Sendable (UInt32, Bool) -> Void)?
    if edgeHooks.isEmpty {
        onEdge = nil
    } else {
        onEdge = { edge, first in for h in edgeHooks { h(edge, first) } }
    }

    let onCompare: (@Sendable (UInt, UInt64, UInt64, UInt32) -> Void)?
    if cmpHooks.isEmpty {
        onCompare = nil
    } else {
        onCompare = { pc, a, b, s in for h in cmpHooks { h(pc, a, b, s) } }
    }

    let onReset: (@Sendable () -> Void)?
    if resetHooks.isEmpty {
        onReset = nil
    } else {
        onReset = { for h in resetHooks { h() } }
    }

    // Vocabularies. Features are namespaced by the substrategy's index; distances
    // are merged per site by the closer value.
    let featureClosures: [(UInt64, @Sendable () -> [UInt64])] =
        engines.enumerated().compactMap { i, e in e.features.map { (UInt64(i), $0) } }
    let features: (@Sendable () -> [UInt64])?
    if featureClosures.isEmpty {
        features = nil
    } else {
        features = {
            var out: [UInt64] = []
            for (salt, produce) in featureClosures {
                for v in produce() { out.append(namespacedFeature(v, salt: salt)) }
            }
            return out
        }
    }

    let distanceClosures = engines.compactMap(\.boundaryDistances)
    let boundaryDistances: (@Sendable () -> [UInt64: UInt64])?
    if distanceClosures.isEmpty {
        boundaryDistances = nil
    } else {
        boundaryDistances = {
            var merged: [UInt64: UInt64] = [:]
            for produce in distanceClosures {
                for (pc, d) in produce() { merged[pc] = min(merged[pc] ?? .max, d) }
            }
            return merged
        }
    }

    // Judgement: run EVERY decision (so each substrategy updates its own novelty
    // oracle — no short-circuit) and OR the results.
    let decides = engines.map(\.decide)
    let decide: CoverageDecision = { coverage in
        var interesting = false
        for d in decides where d(coverage) { interesting = true }
        return interesting
    }

    return CoverageEngine(
        onEdge: onEdge,
        onCompare: onCompare,
        onReset: onReset,
        features: features,
        boundaryDistances: boundaryDistances,
        decide
    )
}
