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

//  Edge coverage as an instrumentation probe: the strategy's per-edge
//  measurement and interestingness judgement, surfaced to schedulers as a
//  per-execution verdict view through the generic `RawExecutionContext` seam.
//

import FuzzCore
import SanCovHooks

/// Names the edge-coverage signal. A scheduler reads `CoverageProbeKey` out of
/// the `RawExecutionContext` to learn whether the strategy judged this
/// execution interesting.
public enum CoverageProbeKey: InstrumentationKey {
    public typealias View = CoverageVerdict
}

/// The coverage probe's per-execution verdict.
public struct CoverageVerdict {
    /// The run's sparse coverage when the strategy judged the input
    /// interesting; `nil` when it covered nothing worth retaining.
    public let coverage: SparseCoverage?

    public init(coverage: SparseCoverage?) {
        self.coverage = coverage
    }
}

/// Drives a `CoverageStrategy`'s per-engine evaluator as an `InstrumentationProbe`.
///
/// Owns the full per-engine measurement lifecycle, so the engine never names
/// coverage to run it: `setUp` allocates the SanCov measurement context and
/// attaches the strategy's edge observer, `withCampaignScope` installs the
/// coverage-inheritance task-local for the loop's lifetime (so edges recorded
/// by child tasks are attributed to this engine), `reset` clears the counters
/// between executions, `makeView` runs the strategy's judgement, and `tearDown`
/// frees the context. It performs no input storage — retaining an interesting
/// input is the engine's job, gated on the scheduler consuming this verdict.
///
/// It owns the *aggregate* covered-edge set (the union of every interesting
/// run's coverage) — coverage-specific bookkeeping that belongs with the
/// coverage probe, not the engine's input store. It is surfaced at campaign end
/// (via `contributeCampaignSummary`) to feed the coverage-gap (`.end`) event.
final class CoverageProbe: InstrumentationProbe {
    typealias Key = CoverageProbeKey

    private let evaluator: CoverageEvaluator
    private let client: CoverageCountersClient

    /// The per-engine measurement context, allocated in `setUp` and freed in
    /// `tearDown`. `nil` before setup / after teardown.
    private var context: SanCovCounters.MeasurementContext?

    /// Union of edge indices across every run this probe judged interesting,
    /// accumulated from the verdicts (not from retained entries, so pool culling
    /// does not shrink the reported total coverage). Surfaced at campaign end for
    /// coverage-gap analysis.
    private(set) var coveredIndices: Set<UInt32> = []

    init(
        evaluator: CoverageEvaluator,
        client: CoverageCountersClient
    ) {
        self.evaluator = evaluator
        self.client = client
    }

    func setUp() {
        // Allocate this engine's measurement context, then let pathTrie and
        // friends attach their edge observer so edges advance per-engine state
        // from the very first iteration.
        let ctx = client.beginMeasurement()
        context = ctx
        evaluator.setup?(ctx)
    }

    func tearDown() {
        if let context {
            client.endMeasurement(context)
        }
        context = nil
    }

    func withCampaignScope(_ body: () async throws -> Void) async rethrows {
        guard let context else {
            try await body()
            return
        }
        // Edges recorded by child tasks (TaskGroup.addTask / Task {}) spawned
        // inside the test body are attributed to this engine's context via the
        // inheritance task-local, set once for the whole loop.
        let bits = context.inheritanceHandle
        try await CoverageInheritance.$context.withValue(bits) {
            CoverageInheritance.captureKeyIfNeeded(contextBits: bits)
            try await body()
        }
    }

    func reset() {
        if let context {
            client.resetCoverage(context)
        }
    }

    func makeView() -> CoverageVerdict {
        guard let context else { return CoverageVerdict(coverage: nil) }
        let coverage = evaluator.evaluate(context, client)
        if let coverage {
            coveredIndices.formUnion(coverage.indices)
        }
        return CoverageVerdict(coverage: coverage)
    }

    /// Surface the union of every interesting run's covered edges to the
    /// campaign-end (`.end`) context, keyed by `CoverageProbeKey` — exactly the
    /// key its per-execution verdict uses. The coverage-gap plugin reads it
    /// from there, so the engine never names coverage to feed `.end`.
    func contributeCampaignSummary(to context: inout RawExecutionContext) {
        context.set(CoverageProbeKey.self, CoverageVerdict(coverage: SparseCoverage(indices: Array(coveredIndices))))
    }
}

/// Builds a `CoverageProbe` per engine for the `CoverageProbeKey` signal. The
/// engine installs probes by matching provider `key`s against the scheduler's
/// `requiredProbes`, so it never names coverage in its install path.
struct CoverageProvider: InstrumentationProvider {
    let key: any InstrumentationKey.Type = CoverageProbeKey.self
    let evaluator: CoverageEvaluator
    let client: CoverageCountersClient

    func makeProbe() -> any InstrumentationProbe {
        CoverageProbe(evaluator: evaluator, client: client)
    }
}
