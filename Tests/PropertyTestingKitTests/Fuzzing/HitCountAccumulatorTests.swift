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

//  Tests for HitCountAccumulator: the lock-free per-edge hit counter that
//  replaces the per-dispatch SyncBox(NSLock) in HitCountBucketsStrategy.onEdge
//  (Finding 42 — that lock was taken ~714x per test). Mirrors
//  BoundarySiteAccumulator: fixed capacity, per-slot atomics, O(occupied) drain.

import Testing
import Foundation
@testable import PropertyTestingKit

@Suite("HitCountAccumulator")
struct HitCountAccumulatorTests {

    @Test("counts hits per edge")
    func countsPerEdge() {
        let acc = HitCountAccumulator()
        for _ in 0..<3 { acc.record(edge: 5) }
        for _ in 0..<2 { acc.record(edge: 9) }

        let counts = Dictionary(uniqueKeysWithValues: acc.snapshot().map { ($0.edge, $0.count) })
        #expect(counts == [5: 3, 9: 2])
    }

    @Test("edge 0 is recorded (not confused with the empty-slot sentinel)")
    func edgeZeroRecorded() {
        let acc = HitCountAccumulator()
        acc.record(edge: 0)
        acc.record(edge: 0)

        let counts = Dictionary(uniqueKeysWithValues: acc.snapshot().map { ($0.edge, $0.count) })
        #expect(counts == [0: 2])
    }

    @Test("reset clears counts but the accumulator is reusable")
    func resetClears() {
        let acc = HitCountAccumulator()
        acc.record(edge: 1)
        acc.reset()
        #expect(acc.snapshot().isEmpty)

        acc.record(edge: 2)
        let counts = Dictionary(uniqueKeysWithValues: acc.snapshot().map { ($0.edge, $0.count) })
        #expect(counts == [2: 1])
    }

    @Test("concurrent records from many threads sum exactly (lock-free)")
    func concurrentRecordsSumExactly() {
        let acc = HitCountAccumulator()
        let threads = 8
        let perThread = 2000

        DispatchQueue.concurrentPerform(iterations: threads) { _ in
            for _ in 0..<perThread { acc.record(edge: 7) }
        }

        let counts = Dictionary(uniqueKeysWithValues: acc.snapshot().map { ($0.edge, $0.count) })
        #expect(counts == [7: UInt32(threads * perThread)])
        #expect(acc.didOverflow == false)
    }
}
