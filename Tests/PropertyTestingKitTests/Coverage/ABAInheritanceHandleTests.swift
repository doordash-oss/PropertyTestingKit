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

//  Regression test for ABA cross-measurement coverage pollution (#53/#56).
//
//  Observed in the full parallel suite: a fresh measurement context saw foreign
//  instrumented guard indices recorded into it (e.g. CountingEdgeHookTests'
//  `firstHitRecordsIndex` seeing covered_count grow past the 2 edges it fired,
//  with consecutive foreign guards like 2898/2899/2900 leaking in). Root cause:
//  coverage inheritance stored the RAW POINTER of the measurement context in a
//  task-local. A straggler task that captured that pointer can outlive the
//  measurement; after the context is freed the allocator can hand the SAME
//  address to an unrelated new measurement. The straggler's stale pointer then
//  aliases the new context, the liveness gate says "live" (it is — but it's the
//  WRONG context), and the straggler's edges pollute the new measurement.
//
//  The fix replaces the raw pointer with a generation-tagged handle: a recycled
//  address carries a new generation, so a stale handle no longer matches.
//
//  This test reproduces the recycled-address condition deterministically WITHOUT
//  relying on the allocator: it mints a "stale" handle that has the SAME pointer
//  as a live context B but a DIFFERENT generation — exactly the bit pattern a
//  straggler holds after B reused an old context's address. A child task fires
//  edges under that stale handle. Pre-fix, those edges route into B (pollution);
//  post-fix, the generation check rejects the stale handle and B is untouched.

import Testing
import SanCovHooks
import EdgeHooks
@testable import PropertyTestingKit

/// Branchy, never-inlined work whose call sites emit sanitizer-coverage edges.
@inline(never)
private func abaHandleEdges(_ seed: Int) -> Int {
    var acc = seed
    for i in 0..<256 {
        if (acc &+ i) % 3 == 0 { acc = acc &* 31 &+ 7 }
        else if (acc &+ i) % 3 == 1 { acc = acc &- 13 }
        else { acc = acc ^ (i &<< 2) }
    }
    return acc
}

@inline(never)
private func blackholeAbaHandle<T>(_ value: T) { withUnsafePointer(to: value) { _ in } }

@Suite("ABA inheritance handle", .serialized, .timeLimit(.minutes(1)))
struct ABAInheritanceHandleTests {

    // Handle layout mirrors sancov_inheritance_handle: high 16 bits = generation,
    // low 48 bits = context pointer.
    private static let ptrBits: UInt = 48
    private static let ptrMask: UInt = (1 << 48) - 1

    /// A handle whose pointer is a live context but whose generation tag is
    /// stale must NOT route edges into that context. This is the exact condition
    /// produced when a context's heap address is recycled by a later, unrelated
    /// measurement while a straggler still holds the old handle.
    @Test("Stale-generation handle aliasing a live context does not pollute it")
    func staleGenerationHandleDoesNotPollute() async {
        // Live context B (registered, has a real generation tag).
        let ctxB = SanCovCounters.beginMeasurement()
        defer { SanCovCounters.endMeasurement(ctxB) }

        let realHandle = ctxB.inheritanceHandle
        let pointerPart = realHandle & Self.ptrMask
        let realGen = realHandle >> Self.ptrBits

        // Forge a handle with B's pointer but a DIFFERENT generation — what a
        // straggler holds after B recycled some earlier context's address.
        let staleGen = (realGen &+ 1) & 0xFFFF
        let staleHandle = (staleGen << Self.ptrBits) | pointerPart
        #expect(staleHandle != realHandle, "forged handle must differ from the live one")

        // Stop THIS task from self-routing into B via the per-task registry, so
        // the only path that could reach B is the inheritance handle. B stays
        // live and active for the liveness/generation gate.
        sancov_remove_task_measurement_for_testing()

        let countBefore = sancov_get_covered_count_with_context(ctxB.rawContext)

        // Fire instrumented edges from a child task inheriting the stale handle,
        // exactly like a straggler spawned inside a (now-recycled) fuzz iteration.
        await CoverageInheritance.$context.withValue(staleHandle) {
            CoverageInheritance.captureKeyIfNeeded(contextBits: staleHandle)
            let child = Task {
                var acc = 0
                for i in 0..<64 { acc &+= abaHandleEdges(i) }
                blackholeAbaHandle(acc)
            }
            await child.value
        }

        let countAfter = sancov_get_covered_count_with_context(ctxB.rawContext)

        // Context-local, pollution-immune signal: B fired no edges of its own, so
        // a correct router (generation-checked) leaves its covered_count at the
        // baseline. Pre-fix the stale handle's edges route into B → count grows.
        #expect(countAfter == countBefore,
                "stale-generation handle polluted live context B; covered_count before=\(countBefore) after=\(countAfter)")
    }

    /// Sanity: a handle with the CORRECT generation still routes (guards against
    /// the fix over-rejecting and silently dropping legitimate inherited edges).
    @Test("Correct-generation handle still routes inherited edges")
    func correctGenerationHandleStillRoutes() async {
        let ctxB = SanCovCounters.beginMeasurement()
        defer { SanCovCounters.endMeasurement(ctxB) }

        let handle = ctxB.inheritanceHandle
        // Isolate the inheritance route (see the stale-handle test).
        sancov_remove_task_measurement_for_testing()
        let countBefore = sancov_get_covered_count_with_context(ctxB.rawContext)

        await CoverageInheritance.$context.withValue(handle) {
            CoverageInheritance.captureKeyIfNeeded(contextBits: handle)
            let child = Task {
                var acc = 0
                for i in 0..<64 { acc &+= abaHandleEdges(i) }
                blackholeAbaHandle(acc)
            }
            await child.value
        }

        let countAfter = sancov_get_covered_count_with_context(ctxB.rawContext)
        #expect(countAfter > countBefore,
                "correct-generation handle must still route inherited edges; before=\(countBefore) after=\(countAfter)")
    }
}
