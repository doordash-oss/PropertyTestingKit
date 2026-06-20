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

//  Unit tests for BoundarySiteAccumulator: the concrete open-addressing
//  PC -> minDistance map that replaces the per-comparison Swift.Dictionary on
//  the boundary cmp hot path. A single atomic word per site holds the minimum
//  |arg1 - arg2| the run drove it to (Findings 45/46/47 removed the sign
//  dimension — it bought no bug-finding). It must reduce by minimum distance,
//  hold many distinct sites within its fixed capacity, aggregate correctly under
//  concurrent (inherited-child-task) records without corruption — it is
//  LOCK-FREE — and reset.

import Testing
@testable import PropertyTestingKit

@Suite("BoundarySiteAccumulator")
struct BoundarySiteAccumulatorTests {

    /// Snapshot as a [pc: distance] dict for order-independent assertions.
    private func asDict(_ acc: BoundarySiteAccumulator) -> [UInt64: UInt64] {
        var out: [UInt64: UInt64] = [:]
        for s in acc.snapshot() { out[s.pc] = s.distance }
        return out
    }

    @Test("keeps the minimum distance across repeated hits of one site")
    func minDistance() {
        let acc = BoundarySiteAccumulator()
        acc.record(pc: 100, distance: 5)
        acc.record(pc: 100, distance: 2)  // closest
        acc.record(pc: 100, distance: 9)  // farther, ignored
        #expect(asDict(acc)[100] == 2)
    }

    @Test("a strictly closer later hit lowers the recorded distance")
    func closerHitLowers() {
        let acc = BoundarySiteAccumulator()
        acc.record(pc: 7, distance: 3)
        acc.record(pc: 7, distance: 0)  // distance 0 = the global min
        #expect(asDict(acc)[7] == 0)
    }

    @Test("distinct sites are all retained")
    func distinctSites() {
        let acc = BoundarySiteAccumulator()
        acc.record(pc: 10, distance: 1)
        acc.record(pc: 20, distance: 2)
        acc.record(pc: 30, distance: 3)
        let d = asDict(acc)
        #expect(d.count == 3)
        #expect(d[10] == 1 && d[20] == 2 && d[30] == 3)
    }

    @Test("a full-width distance is stored without overflow or saturation")
    func fullWidthDistance() {
        let acc = BoundarySiteAccumulator()
        acc.record(pc: 42, distance: UInt64.max)
        #expect(asDict(acc)[42] == UInt64.max)
    }

    @Test("retains many distinct sites within the fixed capacity")
    func manyDistinctSites() {
        let acc = BoundarySiteAccumulator()
        // Far more distinct PCs than the small initial table the old grow-based
        // version started with, but within the fixed capacity. Each hit twice,
        // smaller distance the second time.
        let n: UInt64 = 5000
        for pc in 1...n { acc.record(pc: pc &* 2654435761, distance: 50) }
        for pc in 1...n { acc.record(pc: pc &* 2654435761, distance: 7) }
        let d = asDict(acc)
        #expect(d.count == Int(n))
        #expect(!acc.didOverflow)
        for pc in [UInt64(1), 2500, n] {
            #expect(d[pc &* 2654435761] == 7, "min distance for pc \(pc &* 2654435761)")
        }
    }

    @Test("concurrent records aggregate without corruption (lock-free safety)")
    func concurrentRecords() async {
        let acc = BoundarySiteAccumulator()
        // 8 tasks hammer 16 shared sites at once — the inherited-child-task case
        // the accumulator must survive lock-free. Every task drives each site to
        // distance 0, so the converged min is unambiguous.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    for r in 0..<5000 {
                        let pc = UInt64((r % 16) + 1)
                        let distance = UInt64((r / 16) % 50)  // hits 0 for each site
                        acc.record(pc: pc, distance: distance)
                    }
                }
            }
        }
        let d = asDict(acc)
        #expect(d.count == 16, "no claims lost under contention")
        #expect(!acc.didOverflow)
        for pc in UInt64(1)...16 {
            #expect(d[pc] == 0, "global min survived the races for pc \(pc)")
        }
    }

    @Test("reset clears all entries")
    func resetClears() {
        let acc = BoundarySiteAccumulator()
        acc.record(pc: 1, distance: 1)
        acc.record(pc: 2, distance: 2)
        acc.reset()
        #expect(acc.snapshot().isEmpty)
        // Reusable after reset.
        acc.record(pc: 3, distance: 3)
        #expect(asDict(acc)[3] == 3)
        #expect(acc.snapshot().count == 1)
    }
}
