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

//  Tests for per-context edge recorders: the recorder choice lives on the
//  measurement context (like the trie used to), and `sancov_dispatch_edge`
//  routes each edge to the context's recorder — no process-global hook.
//

import Testing
import Foundation
import SanCovHooks
@testable import PropertyTestingKit

/// Raw pointer bits of a recorder, for comparing against the getter seam.
private func recorderBits(_ hook: EdgeHook) -> UnsafeMutableRawPointer {
    unsafeBitCast(hook, to: UnsafeMutableRawPointer.self)
}

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
            sancov_context_set_recorder(ctx, countingEdgeHook, UnsafeMutableRawPointer(data))
            #expect(sancov_context_get_recorder_for_testing(ctx) == recorderBits(countingEdgeHook))
            #expect(sancov_context_get_recorder_data_for_testing(ctx) == UnsafeMutableRawPointer(data))

            // Clearing: NULL recorder resets both fields.
            sancov_context_set_recorder(ctx, nil, nil)
            #expect(sancov_context_get_recorder_for_testing(ctx) == nil)
            #expect(sancov_context_get_recorder_data_for_testing(ctx) == nil)
        }
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

    @Test("Dispatch advances the trie recorder's trie and still appends covered indices")
    func dispatchTrieRecorderAdvancesAndSnapshots() throws {
        let context = SanCovCounters.beginMeasurement()
        let trie = PathTrie()
        // The recorder contract: the attached data must stay alive until the
        // measurement ends. ARC may release `trie` after its last use, while
        // instrumented edges still dispatch into the trie recorder — keep it
        // alive through endMeasurement (which severs the recorder).
        defer { withExtendedLifetime(trie) { SanCovCounters.endMeasurement(context) } }

        SanCovCounters.attachRecorder(
            trieEdgeHook,
            data: UnsafeMutableRawPointer(trie.rawPointer),
            to: context
        )

        // Both passes must execute IDENTICAL instrumented code between the
        // coverage reset and the uniqueness read — this test file is itself
        // instrumented, and its edges dispatch into the trie too. A single
        // local function gives both passes the same edge sequence; read and
        // mark are adjacent straight-line calls so no instrumented branch edge
        // can land between them and extend the path past the read point.
        func firePass() -> Bool {
            SanCovCounters.resetCoverage(context)   // also resets the trie to root
            var g0: UInt32 = 0
            var g1: UInt32 = 1
            var g2: UInt32 = 2
            sancov_dispatch_edge(&g0)
            sancov_dispatch_edge(&g1)
            sancov_dispatch_edge(&g2)
            let unique = trie.isUniquePath
            trie.markTerminal()    // marking an already-terminal node is a no-op
            return unique
        }

        let firstPassUnique = firePass()

        // The trie recorder must keep feeding covered_indices — corpus entries
        // snapshot sparse coverage from it. (The old standalone trie hook
        // skipped this bookkeeping; that would silently break corpus data.)
        let sparse = try SanCovCounters.snapshotCoveredArrays(with: context)

        let secondPassUnique = firePass()

        #expect(firstPassUnique, "First pass over a path is novel")
        #expect(sparse.count >= 3, "Trie recorder must append covered indices")
        #expect(!secondPassUnique, "Identical replayed path must not be novel")
    }

    // MARK: - The pathTrie strategy attaches its recorder via setup

    @Test("pathTrie's setup attaches the trie recorder and its trie")
    func pathTrieSetupAttachesRecorder() {
        let context = SanCovCounters.beginMeasurement()
        let evaluator: CoverageEvaluator<Int> = CoverageStrategy<Int>.pathTrie.makeEvaluator()
        // The evaluator owns the strategy's trie; keep it alive until
        // endMeasurement severs the recorder (see the trie-dispatch test).
        defer { withExtendedLifetime(evaluator) { SanCovCounters.endMeasurement(context) } }

        evaluator.setup?(context)

        #expect(sancov_context_get_recorder_for_testing(context.rawContext) == recorderBits(trieEdgeHook))
        #expect(sancov_context_get_recorder_data_for_testing(context.rawContext) != nil,
                "The strategy's trie rides along as recorder data")
    }

    @Test("Built-ins other than pathTrie attach nothing (default recorder)")
    func defaultRecorderStrategiesAttachNothing() {
        let context = SanCovCounters.beginMeasurement()
        defer { SanCovCounters.endMeasurement(context) }

        let evaluator: CoverageEvaluator<Int> = CoverageStrategy<Int>.signatureMatch.makeEvaluator()
        evaluator.setup?(context)

        #expect(sancov_context_get_recorder_for_testing(context.rawContext) == nil)
    }

    // MARK: - Lifecycle: end_measurement severs the recorder

    /// Replaces the trie/owner-context unlink machinery: stragglers that retain
    /// the context past `endMeasurement` must dispatch to the default recorder,
    /// never to a recorder whose state (e.g. the trie) Swift may have freed.
    @Test("endMeasurement clears the recorder so stragglers fall back to default")
    func endMeasurementClearsRecorder() {
        let context = SanCovCounters.beginMeasurement()
        let raw = context.rawContext
        // Hold an extra reference so the context outlives endMeasurement,
        // standing in for a straggler child task.
        sancov_retain_for_testing(raw)

        SanCovCounters.attachRecorder(countingEdgeHook, to: context)
        #expect(sancov_context_get_recorder_for_testing(raw) != nil)

        SanCovCounters.endMeasurement(context)

        #expect(sancov_context_get_recorder_for_testing(raw) == nil,
                "endMeasurement must clear the recorder")
        #expect(sancov_context_get_recorder_data_for_testing(raw) == nil,
                "endMeasurement must clear the recorder data")

        sancov_release_for_testing(raw)
    }
}
