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

//  Lock-free per-edge hit counter for HitCountBucketsStrategy's onEdge half.
//
//  Profiling (notebook Finding 42) measured the previous SyncBox(NSLock) being
//  taken ~714x per test (once per edge hit) — the per-DISPATCH lock leak SyncBox
//  was never meant to carry. This removes it the same way BoundarySiteAccumulator
//  removed the cmp-channel lock: a FIXED-capacity open-addressing table over flat
//  atomic arrays, each edge's count bumped with a per-slot atomic add. No lock,
//  no Dictionary SipHash, no copy-on-write ARC on the hot path.
//

import Atomics

/// Open-addressing edge → hitCount map for the per-edge hot path. LOCK-FREE and
/// concurrency-safe (a property that spawns child tasks routes edge hooks from
/// several threads into one inherited context — see BoundarySiteAccumulator's
/// note). Every shared field is a per-slot atomic over a FIXED buffer, so
/// concurrent `record`s never tear and never touch reallocated memory; `reset`/
/// `snapshot` run at `decide`, and a straggler racing them can at worst lose its
/// own late increment, never corrupt memory.
///
/// `@unchecked Sendable` because the raw atomic-storage pointers are not
/// automatically `Sendable`.
final class HitCountAccumulator: @unchecked Sendable {
    /// One occupied slot's snapshot, handed to `decide` once per iteration.
    struct EdgeCount {
        var edge: UInt32
        var count: UInt32
    }

    // Parallel flat buffers (Structure-of-Arrays). `keys[i]` holds `edge + 1`, so
    // 0 marks an empty slot AND edge 0 (a valid index) is representable. `count`
    // is the per-edge hit tally. Capacity is a power of two (mask, not modulo) and
    // FIXED for the accumulator's life.
    private let keys: UnsafeMutablePointer<UInt64.AtomicRepresentation>
    private let count: UnsafeMutablePointer<UInt32.AtomicRepresentation>
    // Occupied slot indices in claim order → O(occupied) snapshot/reset. Written
    // only by the thread that wins a slot's key-claim CAS; -1 = not yet published.
    private let occ: UnsafeMutablePointer<Int.AtomicRepresentation>
    private let occCount = UnsafeAtomic<Int>.create(0)
    // Set once if the table ever fills and an increment is dropped (best-effort;
    // real workloads have far fewer distinct edges-per-run than capacity).
    private let overflowed = UnsafeAtomic<Bool>.create(false)
    private let capacity: Int
    private let mask: Int

    init(initialCapacity: Int = 8192) {
        var cap = 1
        while cap < initialCapacity { cap <<= 1 }
        capacity = cap
        mask = cap - 1
        keys = .allocate(capacity: cap)
        count = .allocate(capacity: cap)
        occ = .allocate(capacity: cap)
        keys.initialize(repeating: UInt64.AtomicRepresentation(0), count: cap)
        count.initialize(repeating: UInt32.AtomicRepresentation(0), count: cap)
        occ.initialize(repeating: Int.AtomicRepresentation(-1), count: cap)
    }

    deinit {
        keys.deinitialize(count: capacity); keys.deallocate()
        count.deinitialize(count: capacity); count.deallocate()
        occ.deinitialize(count: capacity); occ.deallocate()
        occCount.destroy()
        overflowed.destroy()
    }

    /// True iff the fixed table ever filled and dropped an increment. Diagnostic.
    var didOverflow: Bool { overflowed.load(ordering: .relaxed) }

    /// splitmix64 finaliser — cheap, well-distributed. NOT `Swift.Hasher`.
    @inline(__always)
    private static func hash(_ x: UInt64) -> UInt64 {
        var z = x &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Record one hit of `edge`. Lock-free; safe to call concurrently from
    /// inherited child tasks. Steady-state cost is a relaxed load + an atomic add.
    func record(edge: UInt32) {
        let key = UInt64(edge) &+ 1   // edge 0 → key 1; 0 stays the empty sentinel
        var i = Int(Self.hash(key) & UInt64(mask))
        var probes = 0
        while probes <= mask {
            let kAtom = UnsafeAtomic<UInt64>(at: keys + i)
            let k = kAtom.load(ordering: .relaxed)
            if k == key {
                UnsafeAtomic<UInt32>(at: count + i).wrappingIncrement(ordering: .relaxed)
                return
            }
            if k == 0 {
                let (won, _) = kAtom.compareExchange(
                    expected: 0, desired: key, ordering: .acquiringAndReleasing)
                if won {
                    UnsafeAtomic<UInt32>(at: count + i).wrappingIncrement(ordering: .relaxed)
                    let slot = occCount.loadThenWrappingIncrement(ordering: .relaxed)
                    if slot < capacity {
                        UnsafeAtomic<Int>(at: occ + slot).store(i, ordering: .relaxed)
                    }
                    return
                }
                // Lost the claim: if the winner took it for OUR key, bump in place;
                // otherwise keep probing.
                if kAtom.load(ordering: .relaxed) == key {
                    UnsafeAtomic<UInt32>(at: count + i).wrappingIncrement(ordering: .relaxed)
                    return
                }
            }
            i = (i &+ 1) & mask
            probes &+= 1
        }
        // Table full — drop (best-effort signal). Never happens for real workloads.
        overflowed.store(true, ordering: .relaxed)
    }

    /// The occupied (edge, count) pairs. Built once per iteration in `decide`.
    func snapshot() -> [EdgeCount] {
        let n = min(occCount.load(ordering: .acquiring), capacity)
        var out: [EdgeCount] = []
        out.reserveCapacity(n)
        var j = 0
        while j < n {
            let i = UnsafeAtomic<Int>(at: occ + j).load(ordering: .relaxed)
            if i >= 0 && i < capacity {
                let k = UnsafeAtomic<UInt64>(at: keys + i).load(ordering: .relaxed)
                if k != 0 {
                    out.append(EdgeCount(
                        edge: UInt32(truncatingIfNeeded: k &- 1),
                        count: UnsafeAtomic<UInt32>(at: count + i).load(ordering: .relaxed)))
                }
            }
            j &+= 1
        }
        return out
    }

    /// Clear every occupied slot, keeping capacity for the next run. O(occupied).
    func reset() {
        let n = min(occCount.load(ordering: .relaxed), capacity)
        var j = 0
        while j < n {
            let i = UnsafeAtomic<Int>(at: occ + j).load(ordering: .relaxed)
            if i >= 0 && i < capacity {
                UnsafeAtomic<UInt64>(at: keys + i).store(0, ordering: .relaxed)
                UnsafeAtomic<UInt32>(at: count + i).store(0, ordering: .relaxed)
                UnsafeAtomic<Int>(at: occ + j).store(-1, ordering: .relaxed)
            }
            j &+= 1
        }
        occCount.store(0, ordering: .relaxed)
    }
}
