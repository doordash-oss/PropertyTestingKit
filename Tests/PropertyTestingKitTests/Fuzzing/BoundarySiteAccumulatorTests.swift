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
//  PC -> (minDistance, signMask) map that replaces the per-comparison
//  Swift.Dictionary on the boundary cmp hot path. It must reduce by minimum
//  distance, OR sign masks, hold many distinct sites within its fixed capacity,
//  aggregate correctly under concurrent (inherited-child-task) records without
//  corruption — it is LOCK-FREE — and reset.

import Testing
@testable import PropertyTestingKit

@Suite("BoundarySiteAccumulator")
struct BoundarySiteAccumulatorTests {

    /// Snapshot as a [pc: (distance, mask)] dict for order-independent assertions.
    private func asDict(_ acc: BoundarySiteAccumulator) -> [UInt64: (distance: UInt64, mask: UInt8)] {
        var out: [UInt64: (distance: UInt64, mask: UInt8)] = [:]
        for s in acc.snapshot() { out[s.pc] = (s.distance, s.signMask) }
        return out
    }

    @Test("keeps the minimum distance across repeated hits of one site")
    func minDistance() {
        let acc = BoundarySiteAccumulator()
        acc.record(pc: 100, distance: 5, nearBit: 0)
        acc.record(pc: 100, distance: 2, nearBit: 0)
        acc.record(pc: 100, distance: 9, nearBit: 0)
        #expect(asDict(acc)[100]?.distance == 2)
    }

    @Test("ORs every sign bit a site contributes")
    func orsSignMask() {
        let acc = BoundarySiteAccumulator()
        acc.record(pc: 100, distance: 1, nearBit: 0b001)
        acc.record(pc: 100, distance: 0, nearBit: 0b010)
        #expect(asDict(acc)[100]?.mask == 0b011)
        #expect(asDict(acc)[100]?.distance == 0)
    }

    @Test("distinct sites are all retained")
    func distinctSites() {
        let acc = BoundarySiteAccumulator()
        acc.record(pc: 10, distance: 1, nearBit: 1)
        acc.record(pc: 20, distance: 2, nearBit: 2)
        acc.record(pc: 30, distance: 3, nearBit: 4)
        let d = asDict(acc)
        #expect(d.count == 3)
        #expect(d[10]?.mask == 1 && d[20]?.mask == 2 && d[30]?.mask == 4)
    }

    @Test("retains many distinct sites within the fixed capacity")
    func manyDistinctSites() {
        let acc = BoundarySiteAccumulator()
        // Far more distinct PCs than the small initial table the old grow-based
        // version started with, but within the fixed capacity. Each hit twice,
        // smaller distance the second time.
        let n: UInt64 = 5000
        for pc in 1...n { acc.record(pc: pc &* 2654435761, distance: 50, nearBit: 0) }
        for pc in 1...n { acc.record(pc: pc &* 2654435761, distance: 7, nearBit: 0b100) }
        let d = asDict(acc)
        #expect(d.count == Int(n))
        #expect(!acc.didOverflow)
        // Spot-check a few: min distance kept, mask OR'd.
        for pc in [UInt64(1), 2500, n] {
            let key = pc &* 2654435761
            #expect(d[key]?.distance == 7, "min distance for pc \(key)")
            #expect(d[key]?.mask == 0b100, "mask for pc \(key)")
        }
    }

    @Test("concurrent records aggregate without corruption (lock-free safety)")
    func concurrentRecords() async {
        let acc = BoundarySiteAccumulator()
        // 8 tasks hammer 16 shared sites at once — the inherited-child-task case
        // the accumulator must survive lock-free. Every task contributes near-bit
        // (1 << t%3) and at least one distance of 0 per site.
        await withTaskGroup(of: Void.self) { group in
            for t in 0..<8 {
                group.addTask {
                    for r in 0..<5000 {
                        let pc = UInt64((r % 16) + 1)
                        let distance = UInt64((r / 16) % 50)  // hits 0 for each site
                        acc.record(pc: pc, distance: distance, nearBit: UInt8(1 << (t % 3)))
                    }
                }
            }
        }
        let d = asDict(acc)
        #expect(d.count == 16, "no claims lost under contention")
        #expect(!acc.didOverflow)
        for pc in UInt64(1)...16 {
            #expect(d[pc]?.distance == 0, "global min survived the races for pc \(pc)")
            #expect(d[pc]?.mask == 0b111, "all three near-bits OR'd for pc \(pc)")
        }
    }

    @Test("reset clears all entries")
    func resetClears() {
        let acc = BoundarySiteAccumulator()
        acc.record(pc: 1, distance: 1, nearBit: 1)
        acc.record(pc: 2, distance: 2, nearBit: 2)
        acc.reset()
        #expect(acc.snapshot().isEmpty)
        // Reusable after reset.
        acc.record(pc: 3, distance: 3, nearBit: 4)
        #expect(asDict(acc)[3]?.mask == 4)
        #expect(acc.snapshot().count == 1)
    }
}
