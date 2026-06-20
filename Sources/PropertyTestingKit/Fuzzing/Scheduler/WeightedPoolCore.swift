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
    private let packArity: Int
    private let judge: (_ outcome: PoolIterationOutcome) -> PoolAdmission.Verdict
    private let policies: [any PoolPlugin]
    /// Probability each step generates a fresh input rather than mutating a pool
    /// entry: `1` is all generation, `0` is all mutation. Clamped to `0...1`.
    private let generationRatio: Double
    /// Residence bound (`nil` = unbounded): admitting past it evicts the
    /// lowest-weight resident (ties: largest measured input, then newest).
    /// Decouples how finely the vocabulary distinguishes inputs from how many
    /// of them may stay.
    private let capacity: Int?

    /// Typed inputs, index == entry ID (grows append-only, aligned with `weights`).
    private var pool: [(repeat each Input)] = []
    /// Draw weight per entry ID (index == ID; grows append-only).
    private var weights: [Double] = []
    /// Per-entry mutation depth override (entry ID → chain length). Absent
    /// entries mutate at depth 1; set by a policy via `.setMutationDepth`
    /// (e.g. `AdaptiveDepthPolicy`). `next()` chains the mutator this many
    /// times for a `.mutate(id)` directive.
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
    /// Running sum of `weights[id]` over `live`, maintained incrementally so a
    /// weighted draw — now on ~every mutation step (no bursts) — doesn't re-sum
    /// the whole live set each time. Invariant: equals `live.reduce(0){$0+weights[$1]}`.
    private var liveWeightTotal: Double = 0

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
        capacity: Int? = nil,
        rng: FastRNG
    ) {
        self.mutators = (repeat each mutators)
        var n = 0
        (repeat { _ = each mutators; n += 1 }())
        self.packArity = n
        self.judge = admission.makeJudge()
        self.policies = policies
        self.generationRatio = min(1.0, max(0.0, generationRatio))
        self.capacity = capacity.map { max(1, $0) }
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
            // Chain the mutator `entryDepth[id]` times (default 1). A depth
            // policy raises it to push deeper into a productive entry's
            // neighbourhood; each step mutates one random position of the
            // prior result.
            return ScheduledInput(
                input: chainMutate(
                    pool[id], depth: mutationDepth(for: id), inputSize: packArity,
                    rng: &rng, mutators: repeat each mutators
                ),
                poolParentID: id
            )
        }
    }

    /// Report one executed iteration. Reads the coverage verdict out of the
    /// context (the only probe this scheduler requires) and, when the input was
    /// interesting AND admitted, stores the typed input in its own pool — so the
    /// engine never reads a coverage signal itself and owns no pool. Retention is
    /// no longer a per-iteration corpus write: the pool IS the retained set, and
    /// the engine reads it back via `snapshot()` once at run-end.
    func observe(
        _ input: (repeat each Input),
        _ context: RawExecutionContext,
        source: SchedulerSource
    ) {
        let verdict = context[CoverageProbeKey.self]
        let coverage = verdict?.coverage
        // The strategy's culling vocabulary (k-grams, edge-buckets) when it
        // publishes one; the pool widens covered edges otherwise.
        let features = verdict?.features
        // Per-comparison-site distances when the strategy publishes them
        // (`.boundaryDistance`); consumed only by `featureOwnership`.
        let boundaryDistances = verdict?.boundaryDistances
        // The engine only knows external (seed/queue) vs scheduled; for a
        // scheduler-produced input we reconstruct the finer source from the
        // lineage of our own most recent `next()`.
        let poolSource: PoolIterationSource = source == .external ? .queue : lastProduced
        // The scheduler owns the mutators, so it measures the real input size
        // itself — only on accepts (coverage non-nil); size closures may walk
        // the whole input.
        let size = coverage != nil ? measuredSize(of: repeat each input) : nil
        // Returns the new entry id on admission; the engine wants the signature
        // to persist, which is exactly the coverage that was admitted.
        let admittedID = admit(input, coverage: coverage, features: features, inputSize: size,
                               boundaryDistances: boundaryDistances, poolSource: poolSource)
        // Diagnostic: report what we drew, at what depth, and whether it stuck.
        let depth: Int
        if case let .pool(parent) = poolSource { depth = mutationDepth(for: parent) } else { depth = 1 }
        SchedulerProbe.observe?(poolSource, depth, admittedID != nil)
    }

    /// The inputs the pool currently retains, in live (drawable) order — the
    /// scheduler's contribution to the corpus, read once by the engine at
    /// run-end. Evicted entries are already gone from `live`, so the snapshot is
    /// exactly the surviving working set, not a running tally.
    func snapshot() -> [(repeat each Input)] {
        live.map { pool[$0] }
    }

    /// Sum of the mutator-measured sizes across the input pack — the pool's
    /// real REDUCE/eviction size metric. `nil` when no mutator measures
    /// (positions without a `size` closure contribute nothing).
    private func measuredSize(of input: repeat each Input) -> Int? {
        var total = 0
        var measured = false
        for (mutator, value) in repeat (each mutators, each input) {
            guard let size = mutator.size else { continue }
            total += size(value)
            measured = true
        }
        return measured ? total : nil
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
        features: [UInt64]? = nil,
        inputSize: Int? = nil,
        boundaryDistances: [UInt64: UInt64]? = nil,
        poolSource: PoolIterationSource
    ) -> Int? {
        let outcome = PoolIterationOutcome(
            source: poolSource, newCoverage: coverage, features: features,
            inputSize: inputSize, boundaryDistances: boundaryDistances)
        notifyAndApply(.iteration(outcome))

        guard let coverage else { return nil }
        // The pool accounts ownership in the strategy's vocabulary when it
        // publishes one, and widened covered edges otherwise — `resolvedFeatures`
        // is the single definition of that fallback. The admission judge reads
        // the whole outcome (so `featureOwnership` can see distances).
        let resolved = outcome.resolvedFeatures
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
        pool.append(input)
        sizes.append(inputSize)
        livePos[id] = live.count
        live.append(id)
        liveWeightTotal += 1.0
        let parent: Int?
        if case let .pool(p) = poolSource { parent = p } else { parent = nil }
        notifyAndApply(.inserted(id: id, coverage: coverage, features: resolved,
                                 parent: parent, claimed: verdict.claimed))
        return id
    }

    /// How many times `next()` chains the mutator for a `.mutate(id)` directive
    /// on this entry. Defaults to 1 (single-step) until a policy raises it via
    /// `.setMutationDepth`.
    func mutationDepth(for id: Int) -> Int {
        entryDepth[id] ?? 1
    }

    /// The resident a capacity overflow removes: lowest weight, then the
    /// LARGEST measured input, then the NEWEST. Real sizes target the drift
    /// disease directly — the mutation random walk grows inputs, and the
    /// monsters go first. Without measured sizes, evicting old residents
    /// makes the bounded pool a sliding window over that walk, so the
    /// tie-break keeps elders: they anchor the pool on the early, small,
    /// distinctive inputs; newcomers visit, burst, and yield their slot
    /// unless a weight advisor values them. A capacity-evicted owner keeps
    /// its ledger claims as a ghost (the ledger is never told of evictions):
    /// releasing them re-opens the vocabulary and the pool degenerates into a
    /// revolving door of re-claimers.
    private func capacityVictim() -> Int? {
        // Explicit comparator (no negation) so a pathological `size` closure
        // returning `Int.min` can't trap on `-size`.
        live.min { lhs, rhs in
            let (wl, wr) = (weights[lhs], weights[rhs])
            if wl != wr { return wl < wr }              // lowest weight first
            let (sl, sr) = (sizes[lhs] ?? 0, sizes[rhs] ?? 0)
            if sl != sr { return sl > sr }              // largest measured size first
            return lhs > rhs                            // newest (largest id) first
        }
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
                liveWeightTotal -= weights[id]
                let lastID = live[live.count - 1]
                live[pos] = lastID
                live.removeLast()
                if lastID != id { livePos[lastID] = pos }
                entryDepth[id] = nil
                // Re-broadcast so every policy stays consistent with
                // membership it didn't change itself. Terminates: each ID can
                // be removed at most once (the guard above).
                notifyAndApply(.removed(id: id))

            case let .setWeight(id, weight):
                if id < weights.count {
                    let clamped = max(0, weight)
                    // Only live entries contribute to the running total.
                    if livePos[id] != nil { liveWeightTotal += clamped - weights[id] }
                    weights[id] = clamped
                }

            case let .setMutationDepth(id, depth):
                entryDepth[id] = max(1, depth)
            }
        }
    }

    // MARK: - Draw

    private func weightedDraw() -> Int {
        guard liveWeightTotal > 0 else {
            // All-zero pool: uniform fallback rather than starvation.
            return live[Int.random(in: 0..<live.count, using: &rng)]
        }
        var target = Double.random(in: 0..<liveWeightTotal, using: &rng)
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
    let capacity: Int?
    /// The edge-coverage signal this pool culls over. The scheduler vends its own
    /// provider (coverage is no longer hardcoded by the batteries).
    let coverageStrategy: CoverageStrategy

    func makeScheduler<each Input: Codable & Sendable>(
        mutators: repeat Mutator<each Input>
    ) -> FuzzCore.AnyScheduler<repeat each Input> {
        @Dependency(\.fastRNG) var fastRNG
        let core = WeightedPoolCore<repeat each Input>(
            mutators: repeat each mutators,
            admission: admission,
            policies: makePolicies(),
            generationRatio: generationRatio,
            capacity: capacity,
            rng: fastRNG
        )
        // Qualified `FuzzCore.AnyScheduler`: `import Dependencies` re-exports
        // `CombineSchedulers.AnyScheduler`, so the bare name is ambiguous here.
        return FuzzCore.AnyScheduler<repeat each Input>(
            requiredProbes: [CoverageProbeKey.self],
            next: { core.next() },
            observe: { input, context, source in core.observe(input, context, source: source) },
            snapshot: { core.snapshot() }
        )
    }
}

extension WeightedPoolFactory {
    /// Vend the edge-coverage provider this pool's signal needs, fresh per engine.
    func makeProviders() -> [any InstrumentationProvider] {
        @Dependency(\.coverageCounters) var client
        return [CoverageProvider(evaluator: coverageStrategy.makeEvaluator(), client: client)]
    }
}
