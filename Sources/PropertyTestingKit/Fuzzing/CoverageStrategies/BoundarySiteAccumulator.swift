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
//  is an out-of-line libsystem CALL per comparison. The lock came out by making
//  `record` LOCK-FREE over a FIXED-capacity table (the realloc-under-readers
//  race was the only reason a lock was required), updated with per-slot atomics.
//
//  Findings 45/46/47 then removed the sign dimension entirely: the A/B showed
//  the boundary sign vocabulary bought zero bug-finding over the distance
//  gradient, so the accumulator now stores ONLY the per-site minimum distance —
//  one atomic word per bucket, no packing, no sign, no near-window. The
//  steady-state cost is a single relaxed load and a compare.
//

import Atomics

/// Open-addressing PC → minDistance map specialised for the per-comparison hot
/// path.
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
    /// One occupied slot's snapshot, handed to `decide` once per iteration:
    /// a comparison site and the smallest `|arg1 - arg2|` the run drove it to.
    struct Site {
        var pc: UInt64
        var distance: UInt64
    }

    // ONE interleaved buffer of ATOMIC storage (Array-of-Structs): `2 * capacity`
    // words, where bucket `i`'s KEY is at word `2*i` and its minimum-distance
    // VALUE is at `2*i + 1`. The two words of a bucket are adjacent (a 16-byte
    // span), so a steady-state hit reads the key and — on a match — its value
    // from the SAME cache line: one miss per comparison, not the two
    // separate-array misses the old Structure-of-Arrays layout cost (`bucket` is
    // hash-derived, so each access is an effectively random table index). A KEY
    // of 0 marks an empty bucket — a comparison-site PC is
    // `__builtin_return_address`, never 0. The VALUE word starts at `.max` (no
    // distance recorded yet) so the compare-then-CAS min works uniformly for the
    // claiming writer and every later updater (no claim/min race). Capacity is a
    // power of two so the hash maps with a mask, not a modulo, and is FIXED for
    // the accumulator's life.
    private let cells: UnsafeMutablePointer<AtomicRep<UInt64>>
    // Occupied bucket indices, in claim order, so `snapshot`/`reset` are
    // O(occupied) instead of O(capacity). Written only by the thread that wins a
    // bucket's key-claim CAS; `-1` marks an entry not yet published.
    private let occ: UnsafeMutablePointer<AtomicRep<Int>>

    /// Atomic handle for bucket `i`'s KEY word (`cells[2*i]`).
    @inline(__always)
    private func keyWord(_ i: Int) -> UnsafeAtomic<UInt64> {
        UnsafeAtomic<UInt64>(at: cells + (i &<< 1))
    }
    /// Atomic handle for bucket `i`'s packed VALUE word (`cells[2*i + 1]`),
    /// adjacent to its key so the two share a cache line.
    @inline(__always)
    private func valueWord(_ i: Int) -> UnsafeAtomic<UInt64> {
        UnsafeAtomic<UInt64>(at: cells + ((i &<< 1) &+ 1))
    }
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
        cells = .allocate(capacity: cap * 2)
        occ = .allocate(capacity: cap)
        // Interleave: even words = keys (empty sentinel 0), odd words = packed
        // values (min sentinel .max). Bulk-initialize to 0, then raise the value
        // words to the sentinel.
        cells.initialize(repeating: AtomicRep<UInt64>(0), count: cap * 2)
        var j = 0
        while j < cap {
            cells[j * 2 + 1] = AtomicRep<UInt64>(UInt64.max)
            j &+= 1
        }
        occ.initialize(repeating: AtomicRep<Int>(-1), count: cap)
    }

    deinit {
        cells.deinitialize(count: capacity * 2); cells.deallocate()
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

    /// Lower bucket `i`'s value to `distance` if it is a closer approach. The min
    /// is a relaxed load + early-out, then a weak-CAS loop only when the distance
    /// actually improves (rare after a site's first few hits) — so the
    /// steady-state cost is a single relaxed load and a compare, no
    /// read-modify-write and no call.
    @inline(__always)
    private func updateSlot(_ i: Int, distance: UInt64) {
        let value = valueWord(i)
        var cur = value.load(ordering: .relaxed)
        while distance < cur {
            let (done, original) = value.weakCompareExchange(
                expected: cur, desired: distance, ordering: .relaxed)
            if done { break }
            cur = original
        }
    }

    /// Record one comparison: keep, for `pc`, the minimum `distance`
    /// (`|arg1 - arg2|`) any hit drove it to this run. Lock-free; safe to call
    /// concurrently from inherited child tasks.
    ///
    /// `@inline(__always)` because the module builds non-WMO (one `.o` per
    /// source file), so without it this stays an out-of-line cross-file call
    /// from `onCompare` — a tail-branch plus a prologue/epilogue on the
    /// per-comparison hot path. It has a single hot caller (the boundary
    /// engine's `onCompare` closure), so folding it in costs no code size. The
    /// probe-loop helpers (`keyWord`/`valueWord`/`hash`/`updateSlot`) are
    /// already inlined into this body; this carries the whole thing into the
    /// closure.
    @inline(__always)
    func record(pc: UInt64, distance: UInt64) {
        // Open-addressing linear probe: start at this PC's home bucket and walk
        // forward (wrapping with `mask`) until we find the PC, claim an empty
        // slot for it, or exhaust the table. The bound runs at most `mask + 1`
        // times = one full pass over the table. `mask` is hoisted to a local so
        // the loop condition doesn't reload the stored property each iteration
        // (the atomic accesses below are optimizer barriers that would otherwise
        // force a reread of `self`).
        let mask = self.mask
        var bucket = Int(Self.hash(pc) & UInt64(mask))
        var probeCount = 0
        while probeCount <= mask {
            let keyCell = keyWord(bucket)
            let occupant = keyCell.load(ordering: .relaxed)

            // This bucket already belongs to our PC (the steady-state case):
            // fold this hit into its running minimum and we're done.
            if occupant == pc {
                updateSlot(bucket, distance: distance)
                return
            }

            // Empty bucket: try to claim it for our PC with a single CAS.
            if occupant == 0 {
                let (claimedByUs, _) = keyCell.compareExchange(
                    expected: 0, desired: pc, ordering: .acquiringAndReleasing)
                if claimedByUs {
                    updateSlot(bucket, distance: distance)
                    // Append this bucket to the occupied-index list so snapshot
                    // and reset are O(occupied) instead of O(capacity).
                    let occupiedIndex = occCount.loadThenWrappingIncrement(ordering: .relaxed)
                    if occupiedIndex < capacity {
                        UnsafeAtomic<Int>(at: occ + occupiedIndex).store(bucket, ordering: .relaxed)
                    }
                    return
                }
                // We lost the claim race to a concurrent (inherited-child-task)
                // writer. If that writer claimed this bucket for OUR PC too,
                // update it in place; otherwise it took it for some other PC, so
                // keep probing past it.
                if keyCell.load(ordering: .relaxed) == pc {
                    updateSlot(bucket, distance: distance)
                    return
                }
            }

            // Bucket taken by a different PC — advance to the next one.
            bucket = (bucket &+ 1) & mask
            probeCount &+= 1
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
                let k = keyWord(i).load(ordering: .relaxed)
                if k != 0 {
                    let distance = valueWord(i).load(ordering: .relaxed)
                    out.append(Site(pc: k, distance: distance))
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
                keyWord(i).store(0, ordering: .relaxed)
                valueWord(i).store(UInt64.max, ordering: .relaxed)
                UnsafeAtomic<Int>(at: occ + j).store(-1, ordering: .relaxed)
            }
            j &+= 1
        }
        occCount.store(0, ordering: .relaxed)
    }
}
