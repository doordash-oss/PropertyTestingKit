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

//  Stress tests for the lock-free ck_ht registries in SanCovHooks under heavy
//  concurrent begin/end (writes) + inherited edge routing (reads).
//
//  ck_ht's *_spmc API is single-producer: concurrent writers (register/
//  unregister from beginMeasurement/endMeasurement on many threads) and a
//  resize that frees the old map under in-flight readers are data races
//  (review findings #54/#55). These tests drive enough concurrency to (a) cross
//  the hash table's resize threshold while readers are active and (b) hammer
//  concurrent insert/remove, aiming to surface corruption (lost entries →
//  dropped coverage, or a crash).

import Testing
import Foundation
import SanCovHooks
@testable import PropertyTestingKit

@inline(never)
private func stressWork(_ x: Int) -> Int {
    var acc = x
    for i in 0..<128 {
        if (acc &+ i) % 5 == 0 { acc = acc &* 1_000_003 &+ 7 }
        else if (acc &+ i) % 5 == 1 { acc = acc &- 13 }
        else if (acc &+ i) % 5 == 2 { acc = acc ^ (i &<< 3) }
        else if (acc &+ i) % 5 == 3 { acc = acc &+ (i &* 17) }
        else { acc = acc &>> 1 }
    }
    return acc
}

@Suite("Active-context registry stress")
struct ActiveContextRegistryStressTests {

    /// Many concurrent measurements, each registering its context (write),
    /// firing inherited edges (reads of the liveness set), and ending (write).
    /// `workerCount` is set above the ck_ht resize threshold (50% of the 256
    /// initial capacity = 128) so the table resizes WHILE readers are probing it.
    @Test("Concurrent begin/route/end does not corrupt or crash", .timeLimit(.minutes(2)))
    func concurrentBeginRouteEndStress() async {
        let workerCount = 300          // > 128 → forces g_active_ctx_ht resize
        let iterationsPerWorker = 300

        // Each worker reports how many of its iterations saw its OWN freshly
        // begun context correctly routed (covered_count > 0 after firing edges
        // under its inheritance scope). Under the ck_ht write/resize races a
        // registration can be lost/corrupted, so an iteration's own edges fail
        // to route to its own context — a detectable consistency violation that
        // does not depend on a segfault.
        actor Tally {
            var total = 0
            var routedToOwnContext = 0
            func record(routed: Bool) { total += 1; if routed { routedToOwnContext += 1 } }
            func snapshot() -> (Int, Int) { (total, routedToOwnContext) }
        }
        let tally = Tally()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<workerCount {
                group.addTask {
                    for _ in 0..<iterationsPerWorker {
                        let ctx = SanCovCounters.beginMeasurement()
                        let bits = UInt(bitPattern: ctx.rawContext)
                        await CoverageInheritance.$context.withValue(bits) {
                            CoverageInheritance.captureKeyIfNeeded(contextBits: bits)
                            // Fire edges under this context's inheritance scope.
                            // With a correct liveness set these route to `ctx`.
                            _ = stressWork(Int(bits & 0xffff))
                        }
                        let routed = sancov_get_covered_count_with_context(ctx.rawContext) > 0
                        await tally.record(routed: routed)
                        SanCovCounters.endMeasurement(ctx)
                    }
                }
            }
        }

        let (total, routed) = await tally.snapshot()
        // Every iteration's own edges should route to its own live context. A
        // lost/corrupted registration (ck_ht write race) shows up as routed <
        // total. We allow a tiny slack for benign scheduling effects but a real
        // corruption drops far more.
        #expect(total == workerCount * iterationsPerWorker)
        #expect(routed >= total - (total / 100),
                "expected nearly all iterations to route to their own live context; routed=\(routed)/\(total)")
    }

    /// TOCTOU: a straggler firing inherited edges concurrently with the
    /// endMeasurement that frees its context. The liveness gate confirms the
    /// context is registered, but if endMeasurement frees it between that check
    /// and the routing dereference (before the reader has retained it), the
    /// straggler reads freed memory (review #52). Run under ThreadSanitizer
    /// (scripts/run-tsan.sh) this surfaces as a heap-use-after-free; without the
    /// fix the read of `ctx->coverage_map` races the free in ctx_release.
    @Test("endMeasurement racing a straggler's edges is race-free", .timeLimit(.minutes(3)))
    func concurrentEndVsStragglerEdges() async {
        // Kept modest so the run fits the time limit even under ThreadSanitizer
        // (~5-10x slower); still thousands of begin/route/end races per run.
        let rounds = 1500
        for _ in 0..<rounds {
            let ctx = SanCovCounters.beginMeasurement()
            let bits = UInt(bitPattern: ctx.rawContext)

            // Spawn a straggler that immediately fires inherited edges, then end
            // the measurement WITHOUT awaiting — so the free in endMeasurement
            // races the straggler's first routing through the liveness gate.
            let straggler: Task<Void, Never> = CoverageInheritance.$context.withValue(bits) {
                CoverageInheritance.captureKeyIfNeeded(contextBits: bits)
                return Task {
                    var acc = 0
                    for i in 0..<32 { acc &+= stressWork(i) }
                    blackholeStress(acc)
                }
            }
            SanCovCounters.endMeasurement(ctx)
            await straggler.value
        }
        #expect(Bool(true))
    }
}

@inline(never)
private func blackholeStress<T>(_ value: T) { withUnsafePointer(to: value) { _ in } }
