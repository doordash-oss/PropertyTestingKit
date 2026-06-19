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

//  Productivity-weighted, adaptive-depth pool policy. Two per-seed scores spend
//  the mutation budget where it has been paying off, and dig DEEPER on seeds
//  whose shallow neighborhood has been mined out (instead of forever drawing
//  depth-1 siblings of a saturated pool).
//

/// Per-seed scheduling by mutation productivity, advising both the draw weight
/// and the mutation depth:
///
/// - **Score 1 (draw weight).** A mutant that *owns* `n ≥ 1` features spikes its
///   parent's weight `×(1 + n)`; a fruitless one decays it `×decay`. Asymptotic
///   to zero — never zero — so every seed keeps a vanishing-but-positive draw
///   chance (`adaptiveDrawWeightUpdate`).
/// - **Score 2 (mutation depth).** A per-seed cascade of "advance past this
///   depth" scores. Each resolved mutant updates its stop level: a miss climbs
///   it slowly toward a ceiling `< 100` (never reaching it → depth self-caps
///   geometrically), a hit anchors the productive depth. The next depth is
///   re-sampled from the cascade and pushed to the core via `.setMutationDepth`.
///
/// Attribution: a mutant's outcome is only fully known across two events —
/// `.iteration` (fires for every execution, before admission) then maybe
/// `.inserted` (fires only on admission, carrying the parent + owned count). So
/// the policy resolves each mutant on a one-step defer: it stashes the pool
/// iteration's parent + depth, lets a following `.inserted` upgrade it to a hit,
/// and flushes the weight/depth update on the next `.iteration` or `.willDraw`.
public final class AdaptiveDepthPolicy: PoolPlugin {
    private let decay: Double
    private let alpha: Double
    private let ceiling: Double
    private let weightFloor: Double
    private let roll: @Sendable () -> Double

    /// Per-entry state, index == entry ID (append-only, mirrors the core's IDs).
    private var weights: [Double] = []
    private var depthScores: [[Double]] = []
    private var depthFor: [Int] = []

    /// The mutant awaiting resolution (set on a pool `.iteration`, upgraded by a
    /// following `.inserted`, applied on the next flush).
    private var pendingParent: Int?
    private var pendingDepth = 1
    private var pendingHit = false
    private var pendingClaimed = 0

    public init(
        decay: Double = 0.95,
        alpha: Double = 0.02,
        ceiling: Double = 45.0,
        weightFloor: Double = 1e-9,
        roll: (@Sendable () -> Double)? = nil
    ) {
        self.decay = decay
        self.alpha = alpha
        self.ceiling = ceiling
        self.weightFloor = weightFloor
        self.roll = roll ?? { var r = FastRNG(); return Double.random(in: 0..<100, using: &r) }
    }

    public func handle(event: PoolEvent) -> [PoolAction] {
        switch event {
        case let .iteration(outcome):
            let actions = flush()
            if case let .pool(parent) = outcome.source, parent < weights.count {
                pendingParent = parent
                pendingDepth = depthFor[parent]
                pendingHit = false
                pendingClaimed = 0
            } else {
                pendingParent = nil
            }
            return actions

        case let .inserted(id, _, _, parent, claimed):
            // Sequential IDs (admission is the only inserter), so a new entry
            // always extends the arrays by one.
            if id == weights.count {
                weights.append(1.0)
                depthScores.append([0.0])
                depthFor.append(1)
            }
            // A just-admitted mutant of the pending parent is that parent's hit.
            if let parent, parent == pendingParent {
                pendingHit = true
                pendingClaimed = claimed
            }
            return []

        case .removed:
            return []

        case .willDraw:
            return flush()
        }
    }

    /// Resolve the pending mutant: update its parent's draw weight and the
    /// depth-cascade level it stopped at, then re-sample the parent's next depth.
    private func flush() -> [PoolAction] {
        guard let p = pendingParent, p < weights.count else {
            pendingParent = nil
            return []
        }
        pendingParent = nil
        var actions: [PoolAction] = []

        // Score 1 — draw weight.
        weights[p] = adaptiveDrawWeightUpdate(
            weights[p], ownedFeatures: pendingHit ? pendingClaimed : 0,
            decay: decay, floor: weightFloor)
        actions.append(.setWeight(id: p, weights[p]))

        // Score 2 — climb/anchor the level the mutant stopped at...
        let idx = pendingDepth - 1
        while depthScores[p].count <= idx { depthScores[p].append(0.0) }
        depthScores[p][idx] = depthAdvanceUpdate(
            depthScores[p][idx], hit: pendingHit, alpha: alpha, ceiling: ceiling)

        // ...then re-sample the next depth from the cascade.
        let rolls = (0..<depthScores[p].count).map { _ in roll() }
        let newDepth = sampleMutationDepth(scores: depthScores[p], rolls: rolls)
        while depthScores[p].count < newDepth { depthScores[p].append(0.0) }
        depthFor[p] = newDepth
        actions.append(.setMutationDepth(id: p, depth: newDepth))

        return actions
    }
}
