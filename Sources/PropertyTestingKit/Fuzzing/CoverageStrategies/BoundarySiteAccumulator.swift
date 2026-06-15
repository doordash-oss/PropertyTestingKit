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

//  Concrete per-run accumulator for the boundary comparison hot path.
//
//  Profiling the cmp dispatch (notebook Finding 41) found the per-comparison
//  cost was NOT the lock but (a) Swift.Dictionary's SipHash + copy-on-write ARC
//  and (b) unspecialized generic metadata. This type removed both with an
//  open-addressing map over FLAT CONCRETE arrays of trivial element types.
//
//  Finding 41d then found the os_unfair_lock — kept because task-inherited
//  child tasks route cmp hooks from several threads into the SAME accumulator —
//  had itself become the #1 cost (~26% of the cmp channel): the lock/unlock pair
//  is an out-of-line libsystem CALL per comparison. This version removes the lock
//  entirely by making `record` LOCK-FREE: the table is FIXED-capacity (never
//  reallocs — the realloc-under-readers race was the only reason a lock was
//  required), and each slot is updated with per-slot atomics (claim via CAS,
//  distance via a compare-then-CAS min, sign via atomic OR). The common case —
//  re-hitting an already-claimed site whose distance does not improve — is two
//  relaxed atomic loads and a compare, no read-modify-write and no call.
//

import Atomics

/// Open-addressing PC → (minDistance, signMask) map specialised for the
/// per-comparison hot path.
///
/// LOCK-FREE and concurrency-safe. Coverage contexts are keyed by Swift task and
/// INHERITED by child tasks (`g_coverage_inheritance_key` in SanCovHooks.c), so a
/// property that spawns concurrent work (`async let`, `TaskGroup`) routes edge
/// AND cmp hooks from several threads into the SAME context — and thus the same
/// accumulator — at once. (The edge map handles this with an atomic CAS;
/// `.pathTrie` locks its trie.) Here every shared field is a per-slot atomic over
/// a FIXED buffer, so concurrent `record`s never tear and never touch reallocated
/// memory. `reset`/`snapshot` run at `decide`; a straggler child task racing them
/// can at worst lose its own (unwanted) late write — never corrupt memory.
///
/// `@unchecked Sendable` because the raw atomic-storage pointers are not
/// automatically `Sendable`.
final class BoundarySiteAccumulator: @unchecked Sendable {
    /// One occupied slot's snapshot, handed to `decide` once per iteration.
    struct Site {
        var pc: UInt64
        var distance: UInt64
        var signMask: UInt8
    }

    // Parallel flat buffers of ATOMIC storage (Structure-of-Arrays). `keys[i]==0`
    // marks an empty slot — a comparison-site PC is `__builtin_return_address`,
    // never 0, so 0 is a safe empty sentinel. `dist[i]` starts at `.max` so the
    // compare-then-CAS min works uniformly for the claiming writer and every
    // later updater (no claim/min race). Capacity is a power of two so the hash
    // maps with a mask, not a modulo, and is FIXED for the accumulator's life.
    private let keys: UnsafeMutablePointer<UInt64.AtomicRepresentation>
    private let dist: UnsafeMutablePointer<UInt64.AtomicRepresentation>
    private let sign: UnsafeMutablePointer<UInt8.AtomicRepresentation>
    // Occupied slot indices, in claim order, so `snapshot`/`reset` are
    // O(occupied) instead of O(capacity). Written only by the thread that wins a
    // slot's key-claim CAS; `-1` marks an entry not yet published.
    private let occ: UnsafeMutablePointer<Int.AtomicRepresentation>
    private let occCount = UnsafeAtomic<Int>.create(0)
    // Set once if the table ever fills and a record is dropped (best-effort
    // signal; surfaced for diagnostics/tests). Real workloads have far fewer
    // distinct comparison sites than `capacity`, so this stays false.
    private let overflowed = UnsafeAtomic<Bool>.create(false)
    private let capacity: Int
    private let mask: Int

    init(initialCapacity: Int = 8192) {
        var cap = 1
        while cap < initialCapacity { cap <<= 1 }
        capacity = cap
        mask = cap - 1
        keys = .allocate(capacity: cap)
        dist = .allocate(capacity: cap)
        sign = .allocate(capacity: cap)
        occ = .allocate(capacity: cap)
        keys.initialize(repeating: UInt64.AtomicRepresentation(0), count: cap)
        dist.initialize(repeating: UInt64.AtomicRepresentation(UInt64.max), count: cap)
        sign.initialize(repeating: UInt8.AtomicRepresentation(0), count: cap)
        occ.initialize(repeating: Int.AtomicRepresentation(-1), count: cap)
    }

    deinit {
        keys.deinitialize(count: capacity); keys.deallocate()
        dist.deinitialize(count: capacity); dist.deallocate()
        sign.deinitialize(count: capacity); sign.deallocate()
        occ.deinitialize(count: capacity); occ.deallocate()
        occCount.destroy()
        overflowed.destroy()
    }

    /// True iff the fixed table ever filled and dropped a record. Diagnostic.
    var didOverflow: Bool { overflowed.load(ordering: .relaxed) }

    /// splitmix64 finaliser — a cheap, well-distributed mix of the PC. NOT
    /// `Swift.Hasher` (per-process seeded + SipHash, the cost we are removing).
    @inline(__always)
    private static func hash(_ x: UInt64) -> UInt64 {
        var z = x &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Lower `dist[i]` to `distance` if smaller, and OR `nearBit` into `sign[i]`.
    /// The min is a relaxed load + early-out, then a weak-CAS loop only when the
    /// distance actually improves (rare after a site's first few hits) — so the
    /// steady-state cost is a single relaxed load and a compare.
    @inline(__always)
    private func updateSlot(_ i: Int, distance: UInt64, nearBit: UInt8) {
        let d = UnsafeAtomic<UInt64>(at: dist + i)
        var cur = d.load(ordering: .relaxed)
        while distance < cur {
            let (done, original) = d.weakCompareExchange(
                expected: cur, desired: distance, ordering: .relaxed)
            if done { break }
            cur = original
        }
        if nearBit != 0 {
            UnsafeAtomic<UInt8>(at: sign + i).loadThenBitwiseOr(with: nearBit, ordering: .relaxed)
        }
    }

    /// Record one comparison: keep the minimum distance for `pc` and OR in the
    /// near-boundary side bit (`nearBit` is 0 when the hit was outside the
    /// window, contributing nothing to the mask). Lock-free; safe to call
    /// concurrently from inherited child tasks.
    func record(pc: UInt64, distance: UInt64, nearBit: UInt8) {
        var i = Int(Self.hash(pc) & UInt64(mask))
        var probes = 0
        while probes <= mask {
            let kAtom = UnsafeAtomic<UInt64>(at: keys + i)
            let k = kAtom.load(ordering: .relaxed)
            if k == pc {
                updateSlot(i, distance: distance, nearBit: nearBit)
                return
            }
            if k == 0 {
                let (won, _) = kAtom.compareExchange(
                    expected: 0, desired: pc, ordering: .acquiringAndReleasing)
                if won {
                    updateSlot(i, distance: distance, nearBit: nearBit)
                    // Publish this slot's index for O(occupied) snapshot/reset.
                    let slot = occCount.loadThenWrappingIncrement(ordering: .relaxed)
                    if slot < capacity {
                        UnsafeAtomic<Int>(at: occ + slot).store(i, ordering: .relaxed)
                    }
                    return
                }
                // Lost the claim: another thread took this slot. If it took it
                // for OUR pc, update in place; otherwise keep probing.
                if kAtom.load(ordering: .relaxed) == pc {
                    updateSlot(i, distance: distance, nearBit: nearBit)
                    return
                }
            }
            i = (i &+ 1) & mask
            probes &+= 1
        }
        // Table full — drop this record (best-effort signal). Never happens for
        // real workloads (distinct cmp sites ≪ capacity).
        overflowed.store(true, ordering: .relaxed)
    }

    /// The occupied slots. Built once per iteration in `decide`; off the hot path.
    func snapshot() -> [Site] {
        let n = min(occCount.load(ordering: .acquiring), capacity)
        var out: [Site] = []
        out.reserveCapacity(n)
        var j = 0
        while j < n {
            let i = UnsafeAtomic<Int>(at: occ + j).load(ordering: .relaxed)
            if i >= 0 && i < capacity {
                let k = UnsafeAtomic<UInt64>(at: keys + i).load(ordering: .relaxed)
                if k != 0 {
                    out.append(Site(
                        pc: k,
                        distance: UnsafeAtomic<UInt64>(at: dist + i).load(ordering: .relaxed),
                        signMask: UnsafeAtomic<UInt8>(at: sign + i).load(ordering: .relaxed)))
                }
            }
            j &+= 1
        }
        return out
    }

    /// Clear every occupied slot, keeping the allocated capacity for the next
    /// run. Touches only the slots claimed this iteration (O(occupied)).
    func reset() {
        let n = min(occCount.load(ordering: .relaxed), capacity)
        var j = 0
        while j < n {
            let i = UnsafeAtomic<Int>(at: occ + j).load(ordering: .relaxed)
            if i >= 0 && i < capacity {
                UnsafeAtomic<UInt64>(at: keys + i).store(0, ordering: .relaxed)
                UnsafeAtomic<UInt64>(at: dist + i).store(UInt64.max, ordering: .relaxed)
                UnsafeAtomic<UInt8>(at: sign + i).store(0, ordering: .relaxed)
                UnsafeAtomic<Int>(at: occ + j).store(-1, ordering: .relaxed)
            }
            j &+= 1
        }
        occCount.store(0, ordering: .relaxed)
    }
}
