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

//  Tests for the Swift comparison-observer bridge: a strategy expresses
//  per-comparison work as an `onCompare` closure, the measurement context
//  co-owns the observer, and `sancov_dispatch_cmp` routes each comparison's
//  operands to it. Mirrors ContextRecorderTests for the cmp channel.
//

import Testing
import Foundation
import SanCovHooks
@testable import PropertyTestingKit

/// Raw pointer bits of a cmp recorder, for comparing against the getter seam.
private func cmpRecorderBits(_ hook: SanCovCmpRecorder) -> UnsafeMutableRawPointer {
    unsafeBitCast(hook, to: UnsafeMutableRawPointer.self)
}

/// Deinit canary: captured strongly by an observer, held weakly by the test.
private final class Canary: Sendable {}

@Suite("Comparison observers")
struct ComparisonObserverTests {

    @Test("A strategy's onCompare closure receives dispatched comparisons")
    func onCompareReceivesComparisons() {
        let context = SanCovCounters.beginMeasurement()
        defer { SanCovCounters.endMeasurement(context) }

        let seen = PropertyTestingKit.SyncBox<[(UInt, UInt64, UInt64, UInt32)]>([])
        let strategy = CoverageStrategy(makeEngine: {
            CoverageEngine(onCompare: { pc, a, b, size in
                seen.update { $0.append((pc, a, b, size)) }
            }) { _ in false }
        })

        let evaluator = strategy.makeEvaluator()
        evaluator.setup?(context)

        sancov_dispatch_cmp(0xABC, 3, 7, 4)

        #expect(seen.value.contains { $0.0 == 0xABC && $0.1 == 3 && $0.2 == 7 && $0.3 == 4 },
                "onCompare must observe the dispatched comparison's operands")
    }

    @Test("onCompare's setup attaches a comparison observer")
    func setupAttachesComparisonObserver() {
        let context = SanCovCounters.beginMeasurement()
        defer { SanCovCounters.endMeasurement(context) }

        let strategy = CoverageStrategy(makeEngine: {
            CoverageEngine(onCompare: { _, _, _, _ in }) { _ in false }
        })
        let evaluator = strategy.makeEvaluator()
        evaluator.setup?(context)

        #expect(sancov_context_get_cmp_recorder_for_testing(context.rawContext) == cmpRecorderBits(comparisonObserverRecorder))
        #expect(sancov_context_get_cmp_recorder_data(context.rawContext) != nil,
                "The strategy's comparison observer rides along as cmp recorder data")
    }

    /// A strategy with no onCompare attaches no comparison observer — the cmp
    /// channel stays dormant (no per-comparison overhead).
    @Test("A strategy without onCompare attaches no comparison observer")
    func noOnCompareAttachesNothing() {
        let context = SanCovCounters.beginMeasurement()
        defer { SanCovCounters.endMeasurement(context) }

        let evaluator = CoverageStrategy.pathTrie.makeEvaluator()
        evaluator.setup?(context)

        #expect(sancov_context_get_cmp_recorder_for_testing(context.rawContext) == nil,
                "pathTrie attaches an edge observer but no comparison observer")
    }

    @Test("onCompare and onEdge can coexist on one engine")
    func onCompareAndOnEdgeCoexist() {
        let context = SanCovCounters.beginMeasurement()
        defer { SanCovCounters.endMeasurement(context) }

        let edges = PropertyTestingKit.SyncBox<[UInt32]>([])
        let cmps = PropertyTestingKit.SyncBox<Int>(0)
        let strategy = CoverageStrategy(makeEngine: {
            CoverageEngine(
                onEdge: { e, _ in edges.update { $0.append(e) } },
                onCompare: { _, _, _, _ in cmps.update { $0 += 1 } }
            ) { _ in false }
        })
        let evaluator = strategy.makeEvaluator()
        evaluator.setup?(context)

        var g7: UInt32 = 7
        sancov_dispatch_edge(&g7)
        sancov_dispatch_cmp(0x1, 1, 2, 8)

        #expect(edges.value.filter { $0 == 7 }.count >= 1, "the edge observer still fires")
        #expect(cmps.value >= 1, "the comparison observer fires alongside it")
    }

    @Test("The context co-owns the comparison observer after the test drops it")
    func contextSharesOwnership() {
        weak var weakCanary: Canary?
        let context = SanCovCounters.beginMeasurement()

        do {
            let canary = Canary()
            weakCanary = canary
            SanCovCounters.attachComparisonObserver(
                ComparisonObserver(onCompare: { _, _, _, _ in withExtendedLifetime(canary) {} }),
                to: context
            )
        }
        #expect(weakCanary != nil, "The context must retain the observer after attach")

        SanCovCounters.endMeasurement(context)
        #expect(weakCanary == nil, "Freeing the context must release the observer")
    }

    @Test("A comparison observer's onReset fires when coverage is reset")
    func onResetFiresOnResetCoverage() {
        let context = SanCovCounters.beginMeasurement()
        defer { SanCovCounters.endMeasurement(context) }

        let resets = PropertyTestingKit.SyncBox<Int>(0)
        SanCovCounters.attachComparisonObserver(
            ComparisonObserver(onCompare: { _, _, _, _ in }, onReset: { resets.update { $0 += 1 } }),
            to: context
        )

        SanCovCounters.resetCoverage(context)
        #expect(resets.value == 1, "resetCoverage must invoke the comparison observer's onReset")
    }
}
