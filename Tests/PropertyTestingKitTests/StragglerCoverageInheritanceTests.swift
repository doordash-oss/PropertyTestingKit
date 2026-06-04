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
    /// must NOT route its later edges into that (ended) context.
    ///
    /// In production `sancov_end_measurement` unregisters the context from the
    /// liveness set and THEN frees it; a straggler that fires an edge after the
    /// free dereferences `freed_ctx->coverage_map` → intermittent SIGSEGV. Here
    /// we use `sancov_unregister_inheritance_for_testing` to reproduce the
    /// "ended" state deterministically WITHOUT freeing, so we can read the
    /// context's coverage directly. This gives a context-LOCAL signal that is
    /// immune to the process-global route-counter pollution of the parallel
    /// suite: we assert on THIS context's `covered_count`, which no other test
    /// can touch.
    ///
    /// Under the bug (no liveness gate) the straggler resolves the context from
    /// its stale task-local and records edges into it → `covered_count` grows.
    /// Under the fix the gate rejects the unregistered context and the straggler
    /// falls back to thread-local coverage → `covered_count` is unchanged.
    @Test("Straggler edges after a measurement ends do not route into it")
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
                // Fires AFTER the measurement has been unregistered ("ended").
                var acc = 0
                for i in 0..<64 { acc &+= fireEdges(i) }
                blackholeStraggler(acc)
                await done.signal()
            }
        }

        // 2. Wait until the straggler is parked (it still holds `bits`).
        await parked.wait()

        // 3. Mark the measurement ended (unregister) but keep it allocated so we
        //    can inspect its coverage. The straggler's task-local still points at it.
        sancov_unregister_inheritance_for_testing(context.rawContext)
        let countBefore = sancov_get_covered_count_with_context(context.rawContext)

        // 4. Release the straggler to fire its edges against the ended context.
        await proceed.signal()
        await straggler.value
        await done.wait()

        let countAfter = sancov_get_covered_count_with_context(context.rawContext)

        // Context-local, pollution-immune: the straggler's edges must NOT be
        // recorded into the ended context.
        #expect(countAfter == countBefore,
                "straggler edges must not route into the ended context; covered_count before=\(countBefore) after=\(countAfter)")

        SanCovCounters.endMeasurement(context)
    }
}

@inline(never)
private func blackholeStraggler<T>(_ value: T) {
    withUnsafePointer(to: value) { _ in }
}
