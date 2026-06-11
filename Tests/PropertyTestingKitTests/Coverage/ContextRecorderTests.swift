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

//  Tests for per-context edge recorders and Swift edge observers: the recorder
//  choice lives on the measurement context, `sancov_dispatch_edge` routes each
//  edge to it, and a strategy's per-edge work is a Swift closure (EdgeObserver)
//  that the context co-owns — retained at attach, released when the context is
//  freed, so no caller has to pin the observer's state alive.
//

import Testing
import Foundation
import SanCovHooks
import EdgeHooks
@testable import PropertyTestingKit

/// Raw pointer bits of a recorder, for comparing against the getter seam.
private func recorderBits(_ hook: EdgeHook) -> UnsafeMutableRawPointer {
    unsafeBitCast(hook, to: UnsafeMutableRawPointer.self)
}

/// Deinit canary: captured strongly by an observer closure, held weakly by the
/// test. Its lifetime IS the observer's lifetime.
private final class Canary: Sendable {}

@Suite("Per-context edge recorders")
struct ContextRecorderTests {

    // MARK: - Attach / getter round-trip (no routing involved)

    @Test("Attaching a recorder stores it and its data on the context")
    func attachRoundTrip() {
        let ctx = sancov_create_dummy_context()
        defer { sancov_release_for_testing(ctx) }

        #expect(sancov_context_get_recorder_for_testing(ctx) == nil,
                "A fresh context has no recorder (default)")

        var datum: Int = 0
        withUnsafeMutablePointer(to: &datum) { data in
            sancov_context_set_recorder(ctx, countingEdgeHook, UnsafeMutableRawPointer(data), nil, nil)
            #expect(sancov_context_get_recorder_for_testing(ctx) == recorderBits(countingEdgeHook))
            #expect(sancov_context_get_recorder_data(ctx) == UnsafeMutableRawPointer(data))

            // Clearing: NULL recorder resets both fields.
            sancov_context_set_recorder(ctx, nil, nil, nil, nil)
            #expect(sancov_context_get_recorder_for_testing(ctx) == nil)
            #expect(sancov_context_get_recorder_data(ctx) == nil)
        }
    }

    /// The header promises "release is called exactly once" for any
    /// ownership-transferring set_recorder call. That must hold for the
    /// degenerate clear-with-payload shape too — silently dropping the
    /// payload would leak whatever the release hook was meant to free.
    @Test("Clearing the recorder with a payload still releases it exactly once")
    func clearingReleasesPassedPayload() {
        let ctx = sancov_create_dummy_context()
        defer { sancov_release_for_testing(ctx) }

        var releaseCount = 0
        withUnsafeMutablePointer(to: &releaseCount) { counter in
            sancov_context_set_recorder(
                ctx, nil, UnsafeMutableRawPointer(counter), nil,
                { data in data?.assumingMemoryBound(to: Int.self).pointee += 1 }
            )
        }

        #expect(releaseCount == 1,
                "ownership transferred to a cleared slot is released, not dropped")
        #expect(sancov_context_get_recorder_data(ctx) == nil,
                "the cleared slot stores nothing")
    }

    // MARK: - Dispatch routes to the attached recorder

    @Test("Dispatch runs the context's counting recorder, not the default")
    func dispatchUsesAttachedCountingRecorder() {
        let context = SanCovCounters.beginMeasurement()
        defer { SanCovCounters.endMeasurement(context) }

        SanCovCounters.attachRecorder(countingEdgeHook, to: context)

        // Fire the same synthetic guard twice through the dispatch entry.
        // The default recorder is binary (a cell never exceeds 1); only the
        // counting recorder can take it to >= 2. Real instrumented edges may
        // add one first-hit to this cell, so assert >= 2, not == 2.
        var g7: UInt32 = 7
        sancov_dispatch_edge(&g7)
        sancov_dispatch_edge(&g7)

        let cell = context.rawContext.pointee.coverage_map?[7]
        #expect((cell ?? 0) >= 2,
                "Counting recorder should have incremented past the binary 1")
    }

    @Test("Dispatch with no recorder attached uses the binary default")
    func dispatchDefaultsToBinaryRecording() {
        let context = SanCovCounters.beginMeasurement()
        defer { SanCovCounters.endMeasurement(context) }

        var g9: UInt32 = 9
        sancov_dispatch_edge(&g9)
        sancov_dispatch_edge(&g9)

        let cell = context.rawContext.pointee.coverage_map?[9]
        #expect(cell == 1, "Default recorder is binary: repeated hits stay at 1")
    }

    // MARK: - Swift edge observers

    @Test("An observer's onEdge fires on every hit of an edge")
    func observerFiresOnEveryHit() {
        let context = SanCovCounters.beginMeasurement()
        defer { SanCovCounters.endMeasurement(context) }

        let hits = PropertyTestingKit.SyncBox<[UInt32]>([])
        SanCovCounters.attachObserver(
            EdgeObserver(onEdge: { edge, _ in hits.update { $0.append(edge) } }),
            to: context
        )

        // Same synthetic guard three times: the hook runs per HIT — gating
        // (loop immunity, dedup, counting) is the strategy's decision, not the
        // library's. (This test file is instrumented, so its own edges land in
        // `hits` too — filter; a real edge sharing this index can only ADD
        // occurrences, hence >=.)
        var g11: UInt32 = 11
        sancov_dispatch_edge(&g11)
        sancov_dispatch_edge(&g11)
        sancov_dispatch_edge(&g11)

        #expect(hits.value.filter { $0 == 11 }.count >= 3,
                "onEdge must run for every hit, not only the first")
        let cell = context.rawContext.pointee.coverage_map?[11]
        #expect(cell == 1, "Map recording stays binary regardless of hit count")

        let covered = (try? SanCovCounters.snapshotCoveredArrays(with: context)) ?? SparseCoverage()
        #expect(covered.indices.contains(11),
                "The observer recorder must keep feeding covered_indices")
    }

    /// The C layer already computes "first hit this measurement" with a
    /// lock-free CAS on the map bit; the observer passes that bit through so
    /// strategies that want loop immunity (like the trie) don't recompute it
    /// under a lock on every hit. (A real instrumented edge sharing index 17
    /// can only add hits — the map bit still yields exactly one `true` per
    /// reset window, so the counts below are collision-proof.)
    @Test("An observer receives the C first-hit bit per hit")
    func observerReceivesFirstHitBit() {
        let context = SanCovCounters.beginMeasurement()
        defer { SanCovCounters.endMeasurement(context) }

        let firstHits = PropertyTestingKit.SyncBox<[Bool]>([])
        SanCovCounters.attachObserver(
            EdgeObserver(onEdge: { edge, isFirstHit in
                if edge == 17 { firstHits.update { $0.append(isFirstHit) } }
            }),
            to: context
        )

        var g17: UInt32 = 17
        sancov_dispatch_edge(&g17)
        sancov_dispatch_edge(&g17)
        let phase1 = firstHits.value
        SanCovCounters.resetCoverage(context)
        sancov_dispatch_edge(&g17)
        let phase2 = Array(firstHits.value.dropFirst(phase1.count))

        #expect(phase1.count >= 2, "both dispatched hits are observed")
        #expect(phase1.filter { $0 }.count == 1,
                "exactly one first-hit before the reset")
        #expect(phase2.filter { $0 }.count == 1,
                "the reset re-arms the first-hit bit")
    }

    @Test("An observer's onReset fires when coverage is reset")
    func observerOnResetFiresOnResetCoverage() {
        let context = SanCovCounters.beginMeasurement()
        defer { SanCovCounters.endMeasurement(context) }

        let resets = PropertyTestingKit.SyncBox<Int>(0)
        SanCovCounters.attachObserver(
            EdgeObserver(onEdge: { _, _ in }, onReset: { resets.update { $0 += 1 } }),
            to: context
        )

        SanCovCounters.resetCoverage(context)
        #expect(resets.value == 1, "resetCoverage must invoke the observer's onReset")
    }

    // MARK: - Lifecycle: the context co-owns the observer

    @Test("The context keeps the observer (and its captures) alive after the test drops it")
    func contextSharesOwnershipOfObserver() {
        weak var weakCanary: Canary?
        let context = SanCovCounters.beginMeasurement()

        do {
            let canary = Canary()
            weakCanary = canary
            SanCovCounters.attachObserver(
                EdgeObserver(onEdge: { _, _ in withExtendedLifetime(canary) {} }),
                to: context
            )
        }
        // No Swift reference to the observer or canary remains — only the
        // context's retain. This is the shared ownership that deletes the old
        // "keep recorder_data alive until endMeasurement" contract.
        #expect(weakCanary != nil,
                "The context must retain the observer after attach")

        SanCovCounters.endMeasurement(context)
        #expect(weakCanary == nil,
                "Freeing the context must release the observer")
    }

    @Test("Re-attaching releases the previous observer")
    func replaceReleasesPreviousObserver() {
        weak var weakCanary: Canary?
        let context = SanCovCounters.beginMeasurement()
        defer { SanCovCounters.endMeasurement(context) }

        do {
            let canary = Canary()
            weakCanary = canary
            SanCovCounters.attachObserver(
                EdgeObserver(onEdge: { _, _ in withExtendedLifetime(canary) {} }),
                to: context
            )
        }
        #expect(weakCanary != nil)

        SanCovCounters.attachObserver(EdgeObserver(onEdge: { _, _ in }), to: context)
        #expect(weakCanary == nil,
                "Replacing the recorder must release the old observer")
    }

    /// Stragglers that retain the context past `endMeasurement` must dispatch
    /// to the default recorder — but the observer's state must stay alive until
    /// the LAST reference drops, so an in-flight dispatch can never race its free.
    @Test("endMeasurement severs the recorder; the observer lives until the last context ref drops")
    func endMeasurementSeversButObserverOutlivesStragglers() {
        weak var weakCanary: Canary?
        let context = SanCovCounters.beginMeasurement()
        let raw = context.rawContext
        // Hold an extra reference, standing in for a straggler child task.
        sancov_retain_for_testing(raw)

        do {
            let canary = Canary()
            weakCanary = canary
            SanCovCounters.attachObserver(
                EdgeObserver(onEdge: { _, _ in withExtendedLifetime(canary) {} }),
                to: context
            )
        }
        #expect(sancov_context_get_recorder_for_testing(raw) != nil)

        SanCovCounters.endMeasurement(context)

        #expect(sancov_context_get_recorder_for_testing(raw) == nil,
                "endMeasurement must sever the recorder fn")
        #expect(weakCanary != nil,
                "The observer must survive while a straggler still holds the context")

        sancov_release_for_testing(raw)
        #expect(weakCanary == nil,
                "The final context release must release the observer")
    }

    // MARK: - Target-context interludes (schedule fuzzing's routing)

    /// A schedule-drain interlude (`sancov_set_target_context`) rebinds the
    /// thread's cached measurement context to the target but leaves the
    /// per-task fast path's (task, map) pairing intact. A post-interlude
    /// dispatch must not pair the task's own map with the target's context —
    /// that silently appends covered indices (and fires recorder/observer)
    /// on the schedule engine. Companion facet of issue #49.
    @Test("Ending a target-context interlude stops routing into the target")
    func targetContextInterludeRepairsPairing() {
        // The target context is begun (and later ended) on its OWN thread,
        // like a schedule engine's: this thread's task keeps its own routing.
        let targetReady = DispatchSemaphore(value: 0)
        let finish = DispatchSemaphore(value: 0)
        let targetBox = PropertyTestingKit.SyncBox<UnsafeMutablePointer<SanCovMeasurementContext>?>(nil)
        let owner = Thread {
            targetBox.value = sancov_begin_measurement()
            targetReady.signal()
            finish.wait()
            if let target = targetBox.value { sancov_end_measurement(target) }
        }
        owner.start()
        targetReady.wait()
        guard let target = targetBox.value else {
            finish.signal()
            Issue.record("begin_measurement failed on the owner thread")
            return
        }
        defer { finish.signal() }

        // Synthetic tail-of-table indices: cold edges, so the instrumented
        // test code firing real edges during the interlude can't collide.
        let n = UInt32(sancov_get_counter_count())
        var gPrime: UInt32 = n - 3
        var gDuring: UInt32 = n - 2
        var gAfter: UInt32 = n - 1

        sancov_dispatch_edge(&gPrime)        // prime this thread's own routing
        sancov_set_target_context(target)
        sancov_dispatch_edge(&gDuring)       // interlude: routes to the target
        sancov_set_target_context(nil)
        sancov_dispatch_edge(&gAfter)        // must NOT keep flowing to the target

        var count = 0
        let indices = sancov_get_covered_indices(target, &count)
        let covered = Set(UnsafeBufferPointer(start: indices, count: count))
        #expect(covered.contains(gDuring),
                "the interlude dispatch routes to the target context")
        #expect(!covered.contains(gAfter),
                "after the interlude, edges must not land on the target context")
    }

    // MARK: - Strategies attach observers via setup

    @Test("Dispatch advances the pathTrie observer's trie and still appends covered indices")
    func dispatchObserverAdvancesTrieAndSnapshots() throws {
        let context = SanCovCounters.beginMeasurement()
        defer { SanCovCounters.endMeasurement(context) }

        let trie = PathTrie()
        SanCovCounters.attachTrie(trie, to: context)

        // Both passes must execute IDENTICAL instrumented code between the
        // coverage reset and the uniqueness read — this test file is itself
        // instrumented, and its edges dispatch into the observer too. A single
        // local function gives both passes the same edge sequence; read and
        // mark are adjacent straight-line calls so no instrumented branch edge
        // can land between them and extend the path past the read point.
        func firePass() -> Bool {
            SanCovCounters.resetCoverage(context)   // onReset resets the trie to root
            var g0: UInt32 = 0
            var g1: UInt32 = 1
            var g2: UInt32 = 2
            sancov_dispatch_edge(&g0)
            sancov_dispatch_edge(&g1)
            sancov_dispatch_edge(&g1)   // repeat hit: the TRIE strategy gates it out
            sancov_dispatch_edge(&g2)
            let unique = trie.isUniquePath
            trie.markTerminal()    // marking an already-terminal node is a no-op
            return unique
        }

        let firstPassUnique = firePass()

        // The observer recorder must keep feeding covered_indices — corpus
        // entries snapshot sparse coverage from it.
        let sparse = try SanCovCounters.snapshotCoveredArrays(with: context)

        let secondPassUnique = firePass()

        #expect(firstPassUnique, "First pass over a path is novel")
        #expect(sparse.count >= 3, "The observer recorder must append covered indices")
        #expect(!secondPassUnique, "Identical replayed path must not be novel")
    }

    /// Loop immunity is the trie strategy's own policy (the observer reports
    /// every hit), so it is regression-able and needs a direct pin: the two
    /// passes hit the SAME edges but with DIFFERENT repeat counts. With
    /// first-hit gating the paths match (replay → not unique); without it the
    /// extra repeat lengthens pass 2's path into a spuriously unique one.
    @Test("Repeat hit counts don't lengthen the trie path (loop immunity)")
    func repeatHitCountsDoNotLengthenTriePath() {
        let context = SanCovCounters.beginMeasurement()
        defer { SanCovCounters.endMeasurement(context) }

        let trie = PathTrie()
        SanCovCounters.attachTrie(trie, to: context)

        // One parameterized local function keeps the passes' instrumented
        // code identical (see the dispatch test above); only the repeat
        // count differs, which is exactly what loop immunity must absorb.
        func firePass(repeats: Int) -> Bool {
            SanCovCounters.resetCoverage(context)
            var g50: UInt32 = 50
            var g51: UInt32 = 51
            sancov_dispatch_edge(&g50)
            for _ in 0..<repeats {
                sancov_dispatch_edge(&g51)
            }
            let unique = trie.isUniquePath
            trie.markTerminal()
            return unique
        }

        let firstPassUnique = firePass(repeats: 2)
        let secondPassUnique = firePass(repeats: 3)

        #expect(firstPassUnique, "First pass over the path is novel")
        #expect(!secondPassUnique,
                "An extra repeat of an already-hit edge must not make the path unique")
    }

    @Test("pathTrie's setup attaches an edge observer carrying its trie")
    func pathTrieSetupAttachesObserver() {
        let context = SanCovCounters.beginMeasurement()
        defer { SanCovCounters.endMeasurement(context) }

        let evaluator: CoverageEvaluator<Int> = CoverageStrategy.pathTrie.makeEvaluator()
        evaluator.setup?(context)

        #expect(sancov_context_get_recorder_for_testing(context.rawContext) == recorderBits(edgeObserverRecorder))
        #expect(sancov_context_get_recorder_data(context.rawContext) != nil,
                "The strategy's observer (owning the trie) rides along as recorder data")
    }

    @Test("A custom strategy's onEdge closure receives dispatched edges")
    func customStrategyOnEdgeReceivesEdges() {
        let context = SanCovCounters.beginMeasurement()
        defer { SanCovCounters.endMeasurement(context) }

        let hits = PropertyTestingKit.SyncBox<[UInt32]>([])
        let strategy = CoverageStrategy(
            onEdge: { edge, _ in hits.update { $0.append(edge) } }
        ) { _ in false }

        let evaluator: CoverageEvaluator<Int> = strategy.makeEvaluator()
        evaluator.setup?(context)

        var g13: UInt32 = 13
        sancov_dispatch_edge(&g13)
        sancov_dispatch_edge(&g13)

        #expect(hits.value.filter { $0 == 13 }.count >= 2,
                "The custom strategy's onEdge must observe every dispatched hit")
    }

    @Test("Built-ins other than pathTrie attach nothing (default recorder)")
    func defaultRecorderStrategiesAttachNothing() {
        let context = SanCovCounters.beginMeasurement()
        defer { SanCovCounters.endMeasurement(context) }

        let evaluator: CoverageEvaluator<Int> = CoverageStrategy.signatureMatch.makeEvaluator()
        evaluator.setup?(context)

        #expect(sancov_context_get_recorder_for_testing(context.rawContext) == nil)
    }
}
