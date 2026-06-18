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

//  The mutation pool's owner: entries, weights, the generation-ratio draw, AND
//  the typed inputs themselves plus their production (generation + mutation).
//  Mechanism only — admission and weighting policy live in `PoolAdmission` and
//  the child `PoolPlugin`s.
//

import Dependencies
import FuzzCore

/// Per-engine weighted mutation pool. Generic over the input pack because it
/// OWNS the typed inputs it schedules: `pool[id]` holds the input retained under
/// entry `id` (IDs are sequential and never reused; `weights`/`pool` grow in
/// lockstep so they stay aligned by construction).
///
/// Draw model: each step independently either generates a fresh input (with
/// probability `generationRatio`) or weighted-draws one pool entry to mutate —
/// one input at a time, no bursts.
///
/// Confinement: one instance per engine, driven on the engine's task. No
/// internal synchronization.
final class WeightedPoolCore<each Input: Codable & Sendable> {
    private let mutators: (repeat Mutator<each Input>)
    private let inputSize: Int
    private let judge: (SparseCoverage) -> PoolAdmission.Verdict
    private let policies: [any PoolPlugin]
    /// Probability each step generates a fresh input rather than mutating a pool
    /// entry: `1` is all generation, `0` is all mutation. Clamped to `0...1`.
    private let generationRatio: Double

    /// Typed inputs, index == entry ID (grows append-only, aligned with `weights`).
    private var pool: [(repeat each Input)] = []
    /// Draw weight per entry ID (index == ID; grows append-only).
    private var weights: [Double] = []
    /// Live (drawable) entry IDs, swap-removed on eviction.
    private var live: [Int] = []
    /// Entry ID → its position in `live`.
    private var livePos: [Int: Int] = [:]

    /// What this scheduler's most recent `next()` produced, so `observe` can
    /// report the right `PoolIterationSource` to child policies for a
    /// scheduler-produced input (the engine only tells us external vs scheduled).
    private var lastProduced: PoolIterationSource = .generated

    private var rng: FastRNG

    init(
        mutators: repeat Mutator<each Input>,
        admission: PoolAdmission,
        policies: [any PoolPlugin],
        generationRatio: Double,
        rng: FastRNG
    ) {
        self.mutators = (repeat each mutators)
        var n = 0
        (repeat { _ = each mutators; n += 1 }())
        self.inputSize = n
        self.judge = admission.makeJudge()
        self.policies = policies
        self.generationRatio = min(1.0, max(0.0, generationRatio))
        self.rng = rng
    }

    // MARK: - Production (owned by the scheduler)

    /// Produce the next input to run, applying this engine's mutators to its own
    /// pool (mutate) or generating fresh, per the generation-ratio decision.
    func next() -> ScheduledInput<repeat each Input> {
        switch decide() {
        case .generate:
            lastProduced = .generated
            return ScheduledInput(
                input: generateInput(rng: &rng, mutators: repeat each mutators),
                poolParentID: nil
            )
        case .mutate(let id):
            lastProduced = .pool(parent: id)
            return ScheduledInput(
                input: mutateOneRandomPosition(
                    pool[id], inputSize: inputSize, rng: &rng, mutators: repeat each mutators
                ),
                poolParentID: id
            )
        }
    }

    /// Report one executed iteration. Reads the coverage verdict out of the
    /// context (the only probe this scheduler requires) and, when the input was
    /// interesting AND admitted, stores the typed input in its own pool and
    /// returns the coverage to persist in the corpus — so the engine never reads
    /// a coverage signal itself and owns no pool.
    func observe(
        _ input: (repeat each Input),
        _ context: RawExecutionContext,
        source: SchedulerSource
    ) -> SparseCoverage? {
        let coverage = context[CoverageProbeKey.self]?.coverage
        // The engine only knows external (seed/queue) vs scheduled; for a
        // scheduler-produced input we reconstruct the finer source from the
        // lineage of our own most recent `next()`.
        let poolSource: PoolIterationSource = source == .external ? .queue : lastProduced
        // Returns the new entry id on admission; the engine wants the signature
        // to persist, which is exactly the coverage that was admitted.
        return admit(input, coverage: coverage, poolSource: poolSource) != nil ? coverage : nil
    }

    /// Admission core, shared by the public `observe` seam and white-box tests.
    /// Notifies child policies of the iteration, and when the input was
    /// interesting AND admitted, stores it in the pool and returns its new
    /// sequential entry id (else `nil`). `poolSource` is the policy-facing
    /// lineage; the public seam derives it, tests pass it directly.
    @discardableResult
    func admit(
        _ input: (repeat each Input),
        coverage: SparseCoverage?,
        poolSource: PoolIterationSource
    ) -> Int? {
        notifyAndApply(.iteration(PoolIterationOutcome(source: poolSource, newCoverage: coverage)))

        guard let coverage else { return nil }
        let verdict = judge(coverage)
        guard verdict.admit else { return nil }

        let id = weights.count
        weights.append(1.0)
        pool.append(input)
        livePos[id] = live.count
        live.append(id)
        // The admission's own displacements (REDUCE losers) go through the
        // same removal path as child evictions, so every policy hears them.
        apply(verdict.evict.map { .remove(id: $0) })
        notifyAndApply(.inserted(id: id, coverage: coverage))
        return id
    }

    // MARK: - Decision (policy)

    /// One step of the generation-ratio draw model. Internal so white-box tests
    /// can pin the decision directly; `next()` wraps it with production.
    enum PoolDecision: Equatable {
        case generate
        case mutate(id: Int)
    }

    /// Decide the next step: with probability `generationRatio` (or whenever the
    /// pool is empty) generate fresh, otherwise weighted-draw one entry to
    /// mutate. One input at a time — no bursts.
    func decide() -> PoolDecision {
        guard !live.isEmpty, Double.random(in: 0..<1, using: &rng) >= generationRatio else {
            return .generate
        }
        notifyAndApply(.willDraw)
        // A policy may have emptied the pool in response to `.willDraw`.
        guard !live.isEmpty else { return .generate }
        return .mutate(id: weightedDraw())
    }

    // MARK: - Children

    private func notifyAndApply(_ event: PoolEvent) {
        var actions: [PoolAction] = []
        for policy in policies {
            actions.append(contentsOf: policy.handle(event: event))
        }
        apply(actions)
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
                // Re-broadcast so every policy stays consistent with
                // membership it didn't change itself. Terminates: each ID can
                // be removed at most once (the guard above).
                notifyAndApply(.removed(id: id))

            case let .setWeight(id, weight):
                if id < weights.count {
                    weights[id] = max(0, weight)
                }
            }
        }
    }

    // MARK: - Draw

    private func weightedDraw() -> Int {
        var total = 0.0
        for id in live { total += weights[id] }
        guard total > 0 else {
            // All-zero pool: uniform fallback rather than starvation.
            return live[Int.random(in: 0..<live.count, using: &rng)]
        }
        var target = Double.random(in: 0..<total, using: &rng)
        for id in live {
            target -= weights[id]
            if target < 0 { return id }
        }
        return live[live.count - 1]
    }
}

/// Builds a `WeightedPoolCore` per engine and erases it behind `AnyScheduler`.
/// Edge coverage is the only signal the weighted pool consults.
struct WeightedPoolFactory: SchedulerFactory {
    let admission: PoolAdmission
    let makePolicies: @Sendable () -> [any PoolPlugin]
    let generationRatio: Double

    func makeScheduler<each Input: Codable & Sendable>(
        mutators: repeat Mutator<each Input>
    ) -> FuzzCore.AnyScheduler<repeat each Input> {
        @Dependency(\.fastRNG) var fastRNG
        let core = WeightedPoolCore<repeat each Input>(
            mutators: repeat each mutators,
            admission: admission,
            policies: makePolicies(),
            generationRatio: generationRatio,
            rng: fastRNG
        )
        // Qualified `FuzzCore.AnyScheduler`: `import Dependencies` re-exports
        // `CombineSchedulers.AnyScheduler`, so the bare name is ambiguous here.
        return FuzzCore.AnyScheduler<repeat each Input>(
            requiredProbes: [CoverageProbeKey.self],
            next: { core.next() },
            observe: { input, context, source in core.observe(input, context, source: source) }
        )
    }
}
