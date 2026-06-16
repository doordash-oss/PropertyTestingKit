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

//  The mutation pool's owner: entries, weights, and the focus/burst draw
//  loop. Mechanism only — admission and weighting policy live in
//  `PoolAdmission` and the child `PoolPlugin`s.
//

import Dependencies

/// What the engine should run next.
enum PoolDirective: Equatable {
    /// Generate a fresh input from the mutators.
    case generate
    /// Materialize one single-step mutant of pool entry `id`.
    case mutate(id: Int)
}

/// Per-engine pool owner. Non-generic: entries are IDs here; the typed input
/// for each ID is stored engine-side at the same index (IDs are sequential
/// and never reused, so the two stay aligned by construction).
///
/// Draw model (focus + counter): a drawn or freshly admitted entry becomes
/// the focus and receives `burstLength` consecutive mutants; every finished
/// burst is followed by exactly one fresh generation, so the generator arm
/// keeps a fixed share of executions instead of starving as bursts lengthen.
///
/// Confinement: one instance per engine, driven on the engine's task. No
/// internal synchronization.
final class WeightedPoolCore {
    private let judge: (_ outcome: PoolIterationOutcome) -> PoolAdmission.Verdict
    private let policies: [any PoolPlugin]
    private let burstLength: Int
    private let focusOnInsert: Bool
    /// Residence bound (`nil` = unbounded): admitting past it evicts the
    /// lowest-weight resident (ties: oldest). Decouples how finely the
    /// vocabulary distinguishes inputs from how many of them may stay.
    private let capacity: Int?

    /// Draw weight per entry ID (index == ID; grows append-only).
    private var weights: [Double] = []
    /// Per-entry mutation depth override (entry ID → chain length). Absent
    /// entries mutate at depth 1; set by a policy via `.setMutationDepth`.
    private var entryDepth: [Int: Int] = [:]
    /// Real (mutator-measured) input size per entry ID at admission, `nil`
    /// when unmeasured (index == ID, grows append-only). Deliberately NOT
    /// the covered-edge fallback: more covered edges mark a *better* entry,
    /// so the proxy must never feed the eviction order.
    private var sizes: [Int?] = []
    /// Live (drawable) entry IDs, swap-removed on eviction.
    private var live: [Int] = []
    /// Entry ID → its position in `live`.
    private var livePos: [Int: Int] = [:]

    private var focus: Int?
    private var burstRemaining = 0
    /// One fresh generation is owed after every finished burst.
    private var freshOwed = false

    /// Draw RNG, resolved from the `fastRandomNumberGenerator` dependency at
    /// init. Production gets the thread-local `FastRNG`; tests override
    /// `\.fastRandomNumberGenerator` with a deterministic generator so
    /// weighted-draw distributions are reproducible (otherwise pick-count
    /// assertions flake on near-ties).
    private let withRandomNumberGenerator: WithRandomNumberGenerator

    init(
        admission: PoolAdmission,
        policies: [any PoolPlugin],
        burstLength: Int,
        focusOnInsert: Bool,
        capacity: Int? = nil
    ) {
        @Dependency(\.fastRandomNumberGenerator) var fastRandomNumberGenerator
        self.judge = admission.makeJudge()
        self.policies = policies
        self.burstLength = max(1, burstLength)
        self.focusOnInsert = focusOnInsert
        self.capacity = capacity.map { max(1, $0) }
        self.withRandomNumberGenerator = fastRandomNumberGenerator
    }

    /// Report one executed iteration. Returns the new entry's ID when the
    /// outcome was accepted AND admitted — the engine must then store the
    /// input at that index on its side.
    func observe(_ outcome: PoolIterationOutcome) -> Int? {
        notifyAndApply(.iteration(outcome))

        guard let coverage = outcome.newCoverage else { return nil }
        let features = outcome.resolvedFeatures
        let verdict = judge(outcome)
        guard verdict.admit else { return nil }

        // The admission's own displacements (REDUCE losers) go through the
        // same removal path as child evictions, so every policy hears them.
        // They run BEFORE the capacity check — bankruptcies may free the
        // room, sparing an innocent resident.
        apply(verdict.evict.map { .remove(id: $0) })
        if let capacity {
            while live.count >= capacity, let victim = capacityVictim() {
                apply([.remove(id: victim)])
            }
        }

        let id = weights.count
        weights.append(1.0)
        sizes.append(outcome.inputSize)
        livePos[id] = live.count
        live.append(id)
        if focusOnInsert {
            focus = id
            burstRemaining = burstLength
        }
        let parent: Int?
        if case let .pool(p) = outcome.source { parent = p } else { parent = nil }
        notifyAndApply(.inserted(id: id, coverage: coverage, features: features,
                                 parent: parent, claimed: verdict.claimed))
        return id
    }

    /// Decide what the engine runs next.
    func next() -> PoolDirective {
        if let current = focus {
            if burstRemaining > 0 {
                burstRemaining -= 1
                return .mutate(id: current)
            }
            focus = nil
            freshOwed = true
        }
        if freshOwed {
            freshOwed = false
            return .generate
        }

        notifyAndApply(.willDraw)
        guard !live.isEmpty else {
            return .generate
        }
        let id = weightedDraw()
        focus = id
        burstRemaining = burstLength - 1
        return .mutate(id: id)
    }

    // MARK: - Children

    private func notifyAndApply(_ event: PoolEvent) {
        var actions: [PoolAction] = []
        for policy in policies {
            actions.append(contentsOf: policy.handle(event: event))
        }
        apply(actions)
    }

    /// How many times the engine should chain the mutator for a `.mutate(id)`
    /// directive on this entry. Defaults to 1 (single-step) until a policy
    /// raises it via `.setMutationDepth`.
    func mutationDepth(for id: Int) -> Int {
        entryDepth[id] ?? 1
    }

    private func apply(_ actions: [PoolAction]) {
        for action in actions {
            switch action {
            case let .remove(id):
                guard let pos = livePos.removeValue(forKey: id) else { continue }
                let lastID = live[live.count - 1]
                live[pos] = lastID
                live.removeLast()
                if lastID != id { livePos[lastID] = pos }
                if focus == id {
                    focus = nil
                    burstRemaining = 0
                }
                entryDepth[id] = nil
                // Deliberately NO ledger release: a capacity-evicted owner
                // keeps its claims as a ghost. Releasing them re-opens the
                // vocabulary and the pool degenerates into a revolving door
                // of re-claimers (measured on fsub: admission 48% -> 91% of
                // accepts, pure FIFO churn). Ghost ownership is the flood
                // control: a represented feature stays represented.
                // Re-broadcast so every policy stays consistent with
                // membership it didn't change itself. Terminates: each ID can
                // be removed at most once (the guard above).
                notifyAndApply(.removed(id: id))

            case let .setWeight(id, weight):
                if id < weights.count {
                    weights[id] = max(0, weight)
                }

            case let .setMutationDepth(id, depth):
                entryDepth[id] = max(1, depth)
            }
        }
    }

    /// The resident a capacity overflow removes: lowest weight, then the
    /// LARGEST measured input, then the NEWEST. Real sizes target the drift
    /// disease directly — the mutation random walk grows inputs, and the
    /// monsters go first. Without measured sizes, evicting old residents
    /// makes the bounded pool a sliding window over that walk (probed:
    /// FIFO eviction left executed-term size at 2.4x the edge baseline),
    /// so the tie-break keeps elders: they anchor the pool on the early,
    /// small, distinctive inputs; newcomers visit, burst, and yield their
    /// slot unless a weight advisor values them. With an advisor, eviction
    /// defers to it.
    private func capacityVictim() -> Int? {
        live.min { lhs, rhs in
            (weights[lhs], -(sizes[lhs] ?? 0), -lhs)
                < (weights[rhs], -(sizes[rhs] ?? 0), -rhs)
        }
    }

    // MARK: - Draw

    private func weightedDraw() -> Int {
        var total = 0.0
        for id in live { total += weights[id] }
        guard total > 0 else {
            // All-zero pool: uniform fallback rather than starvation. Draw the
            // index through the RNG wrapper, then index `live` outside the
            // closure (it is `@Sendable` and must not capture `self`).
            let count = live.count
            let pick = withRandomNumberGenerator { rng in
                Int.random(in: 0..<count, using: &rng)
            }
            return live[pick]
        }
        // Draw the target point inside the closure (only the local `span` is
        // captured), then walk the live weights to select outside it.
        let span = total
        var target = withRandomNumberGenerator { rng in
            Double.random(in: 0..<span, using: &rng)
        }
        for id in live {
            target -= weights[id]
            if target < 0 { return id }
        }
        return live[live.count - 1]
    }
}
