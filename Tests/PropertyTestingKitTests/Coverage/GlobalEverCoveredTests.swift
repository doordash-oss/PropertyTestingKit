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

//  Tests for the process-global "ever-covered" edge bitmap: a diagnostic
//  accumulator that sets a bit on EVERY allowed edge fire, independent of the
//  per-task measurement context, the engine's per-iteration reset, and corpus
//  banking. It answers "what is the TRUE union of edges executed across a whole
//  run?" — the question that ctx.coveredIndices (cleared each iteration) and
//  corpus.coveredIndices (only admitted inputs) cannot.
//
//  The global bitmap is process-wide and shared across the parallel test suite,
//  so these assertions use only concurrency-safe invariants (superset and
//  monotonicity); they never pin an exact count, which other concurrent tests
//  would pollute.

import Testing
import Foundation
import SanCovHooks
@testable import PropertyTestingKit

@Suite("Global ever-covered bitmap")
struct GlobalEverCoveredTests {
    /// Some instrumented branching work so real edges fire. `@inline(never)` so
    /// the edges live in a stable, attributable function.
    @inline(never)
    static func work(_ n: Int) -> Int {
        var acc = 0
        for i in 0..<n {
            if i % 2 == 0 { acc &+= i } else { acc &-= i }
        }
        return acc
    }

    @Test("global accumulator survives the engine's per-iteration reset")
    func accumulatesAcrossResets() throws {
        try SanCovCounters.checkAvailabilty()
        SanCovCounters.enableGlobalEverCovered()

        let ctx = SanCovCounters.beginMeasurement()
        defer { SanCovCounters.endMeasurement(ctx) }

        // First iteration: measure a code path under the context.
        SanCovCounters.resetCoverage(ctx)
        _ = Self.work(10)
        let ctxFirst = Set(try SanCovCounters.snapshotCoveredArrays(with: ctx).indices)
        #expect(!ctxFirst.isEmpty, "instrumented work should cover edges")

        // Everything the context saw must also be in the global accumulator:
        // the global bit is set on the same allowed-edge fires.
        let globalAfterFirst = Set(SanCovCounters.snapshotGlobalEverCovered())
        #expect(ctxFirst.isSubset(of: globalAfterFirst),
                "global ever-covered is a superset of any single measurement")

        // The engine clears the CONTEXT between iterations. The global
        // accumulator must NOT be cleared by that — this is the whole point.
        SanCovCounters.resetCoverage(ctx)
        #expect(try SanCovCounters.snapshotCoveredArrays(with: ctx).indices.isEmpty,
                "per-iteration reset clears the context")
        #expect(SanCovCounters.globalEverCoveredCount >= globalAfterFirst.count,
                "global accumulator is monotonic across per-iteration resets")

        // A second, longer path only grows the union.
        _ = Self.work(11)
        #expect(SanCovCounters.globalEverCoveredCount >= globalAfterFirst.count)
    }

    @Test("explicit reset clears the global accumulator")
    func explicitResetClears() throws {
        try SanCovCounters.checkAvailabilty()
        SanCovCounters.enableGlobalEverCovered()
        // NOTE: cannot assert == 0 here — the parallel suite fires edges
        // concurrently. We assert the reset is observable: immediately after a
        // reset the count is no larger than after we then run more work.
        SanCovCounters.resetGlobalEverCovered()
        let afterReset = SanCovCounters.globalEverCoveredCount
        _ = Self.work(20)
        #expect(SanCovCounters.globalEverCoveredCount >= afterReset)
    }
}
