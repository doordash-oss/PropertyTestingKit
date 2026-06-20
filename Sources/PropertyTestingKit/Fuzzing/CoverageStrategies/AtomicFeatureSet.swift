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

//  Lock-free insert-only UInt64 set for ComparisonCoverageStrategy's onCompare
//  half — the distinct value-profile features seen this run.
//
//  Replaces the per-dispatch SyncBox(NSLock) (Finding 42) the same way
//  HitCountAccumulator/BoundarySiteAccumulator do: a FIXED-capacity open-
//  addressing table over a flat atomic array, claimed per-slot via CAS. The
//  steady-state hit (a feature already present) is one relaxed load + compare.
//

import Atomics

/// Open-addressing insert-only set of pre-mixed UInt64 feature hashes. LOCK-FREE
/// and concurrency-safe (inherited child tasks route cmp hooks from several
/// threads into one context — see BoundarySiteAccumulator's note). A fixed buffer
/// of per-slot atomics; `reset`/`snapshot` run at `decide`, and a straggler can at
/// worst lose its own late insert, never corrupt memory.
///
/// `@unchecked Sendable` because the raw atomic-storage pointer is not
/// automatically `Sendable`.
final class AtomicFeatureSet: @unchecked Sendable {
    // `keys[i] == 0` marks an empty slot. The feature value 0 is legal, so it is
    // tracked separately by `zeroSeen` rather than stored in the table (same
    // split FeatureHashSet uses for its literal-0 sentinel). Capacity is a power
    // of two (mask, not modulo) and FIXED for the set's life.
    private let keys: UnsafeMutablePointer<AtomicRep<UInt64>>
    // Claimed slot indices in claim order → O(occupied) snapshot/reset. -1 = unset.
    private let occ: UnsafeMutablePointer<AtomicRep<Int>>
    private let occCount = UnsafeAtomic<Int>.create(0)
    private let zeroSeen = UnsafeAtomic<Bool>.create(false)
    private let overflowed = UnsafeAtomic<Bool>.create(false)
    private let capacity: Int
    private let mask: Int

    init(initialCapacity: Int = 8192) {
        var cap = 1
        while cap < initialCapacity { cap <<= 1 }
        capacity = cap
        mask = cap - 1
        keys = .allocate(capacity: cap)
        occ = .allocate(capacity: cap)
        keys.initialize(repeating: AtomicRep<UInt64>(0), count: cap)
        occ.initialize(repeating: AtomicRep<Int>(-1), count: cap)
    }

    deinit {
        keys.deinitialize(count: capacity); keys.deallocate()
        occ.deinitialize(count: capacity); occ.deallocate()
        occCount.destroy()
        zeroSeen.destroy()
        overflowed.destroy()
    }

    /// True iff the fixed table ever filled and dropped an insert. Diagnostic.
    var didOverflow: Bool { overflowed.load(ordering: .relaxed) }

    /// splitmix64 finaliser — cheap, well-distributed. NOT `Swift.Hasher`. The
    /// feature is already a mixed hash, but re-mixing decorrelates it from the
    /// caller's own bucketing so probe chains stay short.
    @inline(__always)
    private static func hash(_ x: UInt64) -> UInt64 {
        var z = x &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Insert one feature. Idempotent; lock-free; safe to call concurrently.
    func insert(_ feature: UInt64) {
        if feature == 0 {
            zeroSeen.store(true, ordering: .relaxed)
            return
        }
        var i = Int(Self.hash(feature) & UInt64(mask))
        var probes = 0
        while probes <= mask {
            let kAtom = UnsafeAtomic<UInt64>(at: keys + i)
            let k = kAtom.load(ordering: .relaxed)
            if k == feature { return }   // already present
            if k == 0 {
                let (won, _) = kAtom.compareExchange(
                    expected: 0, desired: feature, ordering: .acquiringAndReleasing)
                if won {
                    let slot = occCount.loadThenWrappingIncrement(ordering: .relaxed)
                    if slot < capacity {
                        UnsafeAtomic<Int>(at: occ + slot).store(i, ordering: .relaxed)
                    }
                    return
                }
                // Lost the claim: if to OUR feature it's present; else keep probing.
                if kAtom.load(ordering: .relaxed) == feature { return }
            }
            i = (i &+ 1) & mask
            probes &+= 1
        }
        overflowed.store(true, ordering: .relaxed)
    }

    /// The distinct inserted features. Built once per iteration in `decide`.
    func snapshot() -> [UInt64] {
        let n = min(occCount.load(ordering: .acquiring), capacity)
        var out: [UInt64] = []
        out.reserveCapacity(n + 1)
        if zeroSeen.load(ordering: .relaxed) { out.append(0) }
        var j = 0
        while j < n {
            let i = UnsafeAtomic<Int>(at: occ + j).load(ordering: .relaxed)
            if i >= 0 && i < capacity {
                let k = UnsafeAtomic<UInt64>(at: keys + i).load(ordering: .relaxed)
                if k != 0 { out.append(k) }
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
                UnsafeAtomic<Int>(at: occ + j).store(-1, ordering: .relaxed)
            }
            j &+= 1
        }
        occCount.store(0, ordering: .relaxed)
        zeroSeen.store(false, ordering: .relaxed)
    }
}
