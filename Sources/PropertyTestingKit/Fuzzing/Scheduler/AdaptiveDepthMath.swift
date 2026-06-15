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

//  Pure scoring math for the productivity-weighted, adaptive-depth pool policy.
//  Kept as free functions, pinned by characterization tests (AdaptiveDepthMathTests),
//  so the formulas are decided once and the policy just wires them onto events.
//

/// Score 1 — per-seed draw weight. A mutant that *owns* `n ≥ 1` coverage
/// features spikes its parent's weight by `×(1 + n)` (more ownership → bigger
/// spike); a fruitless mutant decays it by `×decay`. The decay is asymptotic to
/// zero — a seed's draw chance shrinks indefinitely but never vanishes — so the
/// `floor` exists only to keep floating-point from underflowing to a literal 0.
func adaptiveDrawWeightUpdate(
    _ weight: Double,
    ownedFeatures n: Int,
    decay: Double = 0.95,
    floor: Double = 1e-9
) -> Double {
    let next = n > 0 ? weight * (1.0 + Double(n)) : weight * decay
    return max(floor, next)
}

/// Score 2 — one level of the per-seed depth cascade. `score` is the "advance
/// past this depth" likelihood (×100). A **miss** at this level climbs it slowly
/// toward `ceiling` by a fraction `alpha` of the remaining gap — an exponential
/// approach that never reaches the ceiling, so (with `ceiling < 100`) every
/// level always keeps a positive chance of *stopping*, which is exactly what
/// makes depth self-cap geometrically. A **hit** anchors the productive depth by
/// decaying the score back down.
///
/// Defaults `alpha=0.02, ceiling=45` are the swept optimum (2026-06-14, Finding
/// 31): the original `0.05/90` escalated depth to a mean of ~7 straight into the
/// 0%-productive deep tail, halving the solve rate on compound-structure bugs.
/// The shallower climb keeps depth in the productive band while the cascade can
/// still reach deep rungs when a seed genuinely stalls (ceiling is an asymptote,
/// not a hard cap).
func depthAdvanceUpdate(
    _ score: Double,
    hit: Bool,
    alpha: Double = 0.02,
    ceiling: Double = 45.0,
    anchorDecay: Double = 0.95
) -> Double {
    hit ? score * anchorDecay : score + alpha * (ceiling - score)
}

/// Score 2 — sample a mutation depth from the per-seed cascade. `scores[i]` is
/// the advance-past likelihood (×100) for depth `i + 1`. Walking from the
/// shallowest level: a roll `r ∈ [0, 100)` below `scores[i]` advances to the
/// next level, otherwise we stop and emit depth `i + 1`. Advancing past every
/// known level emits a brand-new deeper rung (`scores.count + 1`) — how depth
/// ratchets up one step at a time. `rolls` injects the per-level draws for
/// determinism; an exhausted roll stream stops (treated as `100`).
func sampleMutationDepth(scores: [Double], rolls: [Double]) -> Int {
    var i = 0
    while i < scores.count {
        let r = i < rolls.count ? rolls[i] : 100.0
        if r < scores[i] { i += 1 } else { return i + 1 }
    }
    return scores.count + 1
}
