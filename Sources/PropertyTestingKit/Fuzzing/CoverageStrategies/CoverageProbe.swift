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
/// Owns the measurement context for one engine: `setUp` attaches the strategy's
/// edge observer, `reset` clears the counters between executions, and `makeView`
/// runs the strategy's judgement and reports the verdict. It performs no
/// storage — retaining an interesting input is the engine's job, gated on the
/// scheduler consuming this verdict.
final class CoverageProbe: InstrumentationProbe {
    typealias Key = CoverageProbeKey

    private let evaluator: CoverageEvaluator
    private let context: SanCovCounters.MeasurementContext
    private let client: CoverageCountersClient

    init(
        evaluator: CoverageEvaluator,
        context: SanCovCounters.MeasurementContext,
        client: CoverageCountersClient
    ) {
        self.evaluator = evaluator
        self.context = context
        self.client = client
    }

    func setUp() {
        // pathTrie and friends attach their edge observer here so edges
        // advance per-engine state from the very first iteration.
        evaluator.setup?(context)
    }

    func reset() {
        client.resetCoverage(context)
    }

    func makeView() -> CoverageVerdict {
        CoverageVerdict(coverage: evaluator.evaluate(context, client))
    }
}
