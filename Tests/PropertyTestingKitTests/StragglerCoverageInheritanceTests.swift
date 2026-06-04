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

//  Regression test for the parallel coverage-context use-after-free.
//
//  Coverage measurements propagate to child tasks through the
//  `CoverageInheritance.context` task-local (the raw bits of the active
//  `SanCovMeasurementContext`). An *unstructured* task spawned inside a fuzz
//  iteration captures those bits at creation and can outlive both the
//  `withValue` scope and the `endMeasurement` that frees the context — e.g. a
//  GenericTimerPoller polling loop. When such a straggler later fires a coverage
//  edge, `get_current_coverage_map` used to resolve the (now-freed) context from
//  the stale task-local and dereference `freed_ctx->coverage_map` → SIGSEGV.
//
//  The fix gates every inherited-context lookup through the active-context
//  registry (`is_active_inheritance_context`): a context that has been ended is
//  unregistered before it is freed, so a straggler routes to thread-local
//  fallback instead of a freed pointer.

import Testing
import Foundation
import SanCovHooks
@testable import PropertyTestingKit

/// Minimal async gate: `wait()` suspends until some task calls `signal()`.
private actor Gate {
    private var isSignaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        isSignaled = true
        let pending = waiters
        waiters = []
        for c in pending { c.resume() }
    }

    func wait() async {
        if isSignaled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// Branchy, never-inlined work so the call site emits sanitizer-coverage edges
/// that route through `get_current_coverage_map`.
@inline(never)
private func fireEdges(_ seed: Int) -> Int {
    var acc = seed
    for i in 0..<256 {
        if (acc &+ i) % 3 == 0 {
            acc = acc &* 31 &+ 7
        } else if (acc &+ i) % 3 == 1 {
            acc = acc &- 13
        } else {
            acc = acc ^ (i &<< 2)
        }
    }
    return acc
}

@Suite("Straggler coverage inheritance", .serialized, .timeLimit(.minutes(1)))
struct StragglerCoverageInheritanceTests {

    /// A task that inherited a measurement context and outlives the measurement
    /// must NOT route its later edges into the (ended, freed) context.
    ///
    /// We assert on routing rather than on a crash: the use-after-free read is
    /// only an *intermittent* SIGSEGV (it faults only when the freed block has
    /// been unmapped/reused), but the wrong routing is deterministic. Under the
    /// bug the straggler's edges resolve the freed context from its stale
    /// task-local and take the `inherited_runtime` path (a UAF read each time).
    /// Under the fix the active-context liveness gate rejects the ended context
    /// and the edges fall back to thread-local coverage
    /// (`tls_fallback_inheritance_active`).
    ///
    /// The assertion is a *lower bound* on the fallback bucket, which is robust
    /// under swift-testing's parallel suite: concurrent tests can only add to
    /// these process-global counters, never subtract.
    @Test("Straggler edges after endMeasurement fall back, not route to the freed context")
    func stragglerAfterEndMeasurementDoesNotRouteToFreedContext() async {
        let parked = Gate()      // straggler signals it has captured bits & parked
        let proceed = Gate()     // test signals straggler to fire edges
        let done = Gate()        // straggler signals completion

        // 1. Begin a measurement and capture the inheritance key, exactly like
        //    FuzzStateMachine. Spawn an UNSTRUCTURED task inside the withValue
        //    scope so it inherits the context bits in its task-local chain.
        let context = SanCovCounters.beginMeasurement()
        let bits = UInt(bitPattern: context.rawContext)

        let straggler: Task<Void, Never> = CoverageInheritance.$context.withValue(bits) {
            CoverageInheritance.captureKeyIfNeeded(contextBits: bits)
            return Task {
                await parked.signal()
                await proceed.wait()
                // Fires AFTER the measurement has ended + been freed.
                var acc = 0
                for i in 0..<64 { acc &+= fireEdges(i) }
                blackholeStraggler(acc)
                await done.signal()
            }
        }

        // 2. Wait until the straggler is parked (it still holds `bits`).
        await parked.wait()

        // 3. End the measurement — frees the SanCovMeasurementContext. The
        //    straggler's task-local still points at the freed pointer.
        SanCovCounters.endMeasurement(context)

        // 4. Release the straggler and measure where its edges routed.
        var before = SanCovRouteCounters()
        sancov_read_route_counters(&before)
        await proceed.signal()
        await straggler.value
        await done.wait()
        var after = SanCovRouteCounters()
        sancov_read_route_counters(&after)

        let inheritedDelta = after.inherited_runtime - before.inherited_runtime
        let fallbackDelta = after.tls_fallback_inheritance_active - before.tls_fallback_inheritance_active

        // The straggler fires tens of thousands of edge hits. Under the fix they
        // route to fallback; this lower bound fails under the bug (where they
        // route to the freed context via `inherited_runtime` instead).
        #expect(fallbackDelta >= 1000,
                "straggler edges must fall back to thread-local after the inherited context ended; fallbackΔ=\(fallbackDelta) inheritedΔ=\(inheritedDelta)")
    }
}

@inline(never)
private func blackholeStraggler<T>(_ value: T) {
    withUnsafePointer(to: value) { _ in }
}
