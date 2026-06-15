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
//  on every write (~52% of the cmp channel) and (b) the unspecialized generic
//  `SyncBox.update<A>` instantiating the big `DistanceState` struct's metadata
//  at runtime (~27%). This type removes both: an open-addressing map over FLAT
//  CONCRETE arrays of trivial element types (no generics → no runtime metadata,
//  no Hasher → a cheap multiply-mix, no per-element ARC), reached through a
//  NON-generic `record(pc:distance:nearBit:)` method. The map keys on the
//  comparison site PC, reducing repeated hits of one site (a loop body) to the
//  minimum |arg1-arg2| and the OR of the near-boundary side bits.
//

import Foundation
import os

/// Open-addressing PC → (minDistance, signMask) map specialised for the
/// per-comparison hot path.
///
/// SYNCHRONISED — `record`/`snapshot`/`reset` can run concurrently and MUST be
/// serialised. Coverage contexts are keyed by Swift task and INHERITED by child
/// tasks (`g_coverage_inheritance_key` in SanCovHooks.c), so a property that
/// spawns concurrent work (`async let`, `TaskGroup`) routes edge AND cmp hooks
/// from several threads into the SAME context — and thus the same accumulator —
/// at once. (The edge map handles this with an atomic CAS; `.pathTrie` locks
/// its trie for the same reason.) A lock-free open-addressing map would race on
/// insert and on `grow`'s realloc, so we lock — but with `os_unfair_lock`
/// (`OSAllocatedUnfairLock`), not `NSLock`: profiling showed `NSLock` +
/// `objc_msgSend` cost ~25% of the cmp channel; the unfair lock is a couple of
/// atomic ops (notebook Finding 41). `@unchecked` because the raw-pointer
/// storage is not automatically `Sendable`.
final class BoundarySiteAccumulator: @unchecked Sendable {
    /// One occupied slot's snapshot, handed to `decide` once per iteration.
    struct Site {
        var pc: UInt64
        var distance: UInt64
        var signMask: UInt8
    }

    // Parallel flat buffers (Structure-of-Arrays): `keys[i] == 0` marks an empty
    // slot. A comparison site PC is `__builtin_return_address`, never 0, so 0 is
    // a safe empty sentinel. Capacity is always a power of two so the hash maps
    // with a mask, not a modulo.
    //
    // RAW UnsafeMutablePointer storage, not Swift arrays: indexing a `var`
    // array property in place trips dynamic exclusivity enforcement
    // (`swift_beginAccess`/`AccessSet`, ~25-30% of the cmp channel even in
    // release), bounds checks, and copy-on-write ARC. Pointer subscripts have
    // none of that. Elements are trivial, so deallocate needs no deinitialize.
    private var keys: UnsafeMutablePointer<UInt64>
    private var dist: UnsafeMutablePointer<UInt64>
    private var mask: UnsafeMutablePointer<UInt8>
    private var count: Int = 0
    private var capacity: Int
    private let lock = OSAllocatedUnfairLock()

    init(initialCapacity: Int = 256) {
        var cap = 1
        while cap < initialCapacity { cap <<= 1 }
        capacity = cap
        keys = UnsafeMutablePointer<UInt64>.allocate(capacity: cap)
        dist = UnsafeMutablePointer<UInt64>.allocate(capacity: cap)
        mask = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
        keys.initialize(repeating: 0, count: cap)
        dist.initialize(repeating: 0, count: cap)
        mask.initialize(repeating: 0, count: cap)
    }

    deinit {
        keys.deallocate()
        dist.deallocate()
        mask.deallocate()
    }

    /// splitmix64 finaliser — a cheap, well-distributed mix of the PC. NOT
    /// `Swift.Hasher` (per-process seeded + SipHash, the cost we are removing).
    @inline(__always)
    private static func hash(_ x: UInt64) -> UInt64 {
        var z = x &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Record one comparison: keep the minimum distance for `pc` and OR in the
    /// near-boundary side bit (`nearBit` is 0 when the hit was outside the
    /// window, contributing nothing to the mask).
    func record(pc: UInt64, distance: UInt64, nearBit: UInt8) {
        lock.lock()
        defer { lock.unlock() }
        if (count &+ 1) &* 4 > capacity &* 3 { grow() }
        let m = capacity &- 1
        var i = Int(Self.hash(pc) & UInt64(m))
        while true {
            let k = keys[i]
            if k == pc {
                if distance < dist[i] { dist[i] = distance }
                mask[i] |= nearBit
                return
            }
            if k == 0 {
                keys[i] = pc
                dist[i] = distance
                mask[i] = nearBit
                count &+= 1
                return
            }
            i = (i &+ 1) & m
        }
    }

    /// Insert into a freshly-sized table without bounds growth or min/OR logic
    /// (every key being rehashed is already unique).
    private func insertRaw(pc: UInt64, distance: UInt64, signMask: UInt8) {
        let m = capacity &- 1
        var i = Int(Self.hash(pc) & UInt64(m))
        while keys[i] != 0 { i = (i &+ 1) & m }
        keys[i] = pc
        dist[i] = distance
        mask[i] = signMask
    }

    private func grow() {
        let oldKeys = keys, oldDist = dist, oldMask = mask, oldCap = capacity
        capacity <<= 1
        keys = UnsafeMutablePointer<UInt64>.allocate(capacity: capacity)
        dist = UnsafeMutablePointer<UInt64>.allocate(capacity: capacity)
        mask = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        keys.initialize(repeating: 0, count: capacity)
        dist.initialize(repeating: 0, count: capacity)
        mask.initialize(repeating: 0, count: capacity)
        for i in 0..<oldCap where oldKeys[i] != 0 {
            insertRaw(pc: oldKeys[i], distance: oldDist[i], signMask: oldMask[i])
        }
        oldKeys.deallocate()
        oldDist.deallocate()
        oldMask.deallocate()
    }

    /// The occupied slots. Built once per iteration in `decide`; off the hot path.
    func snapshot() -> [Site] {
        lock.lock()
        defer { lock.unlock() }
        var out: [Site] = []
        out.reserveCapacity(count)
        for i in 0..<capacity where keys[i] != 0 {
            out.append(Site(pc: keys[i], distance: dist[i], signMask: mask[i]))
        }
        return out
    }

    /// Clear every slot, keeping the allocated capacity for the next run. Only
    /// the key sentinels need clearing (occupancy is `keys[i] != 0`).
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        guard count != 0 else { return }
        keys.update(repeating: 0, count: capacity)
        count = 0
    }
}
