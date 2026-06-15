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

//  An open-addressing UInt64 membership set keyed on the value directly — NO
//  Swift Hasher (SipHash). The value-aware novelty oracles (boundaryState's
//  seenSigns, comparisonCoverage's seenFeatures) store feature keys that are
//  ALREADY splitmix64-mixed hashes (see BoundarySignEncoding.encodeBoundarySign*
//  / comparisonFeature). Running them through Set<UInt64> re-hashed already-
//  uniform bits with SipHash on the hottest per-iteration path — ~2.5% of the
//  process purely in Hasher (scheduler-lab Finding 41n). Indexing on the value's
//  own (already-mixed) low bits removes that entirely; the same trick
//  BoundarySiteAccumulator uses for its PC keys.

/// Open-addressing set of UInt64 feature keys with `.inserted` semantics. The
/// keys are assumed pre-mixed (uniform low bits), so the probe index is the
/// value itself masked — no secondary hashing. Linear probing; grows at a 0.75
/// load factor. The literal value `0` is tracked separately so an empty slot
/// (also 0) is never mistaken for a stored 0.
struct FeatureHashSet {
    /// 0 marks an empty slot; a stored literal 0 is tracked by `hasZero`.
    private var slots: [UInt64]
    private var mask: UInt64
    /// Non-zero members held in `slots` (excludes the separately-tracked 0).
    private var occupied: Int
    private var hasZero: Bool

    init(minimumCapacity: Int = 64) {
        var cap = 64
        while cap < minimumCapacity { cap <<= 1 }
        slots = [UInt64](repeating: 0, count: cap)
        mask = UInt64(cap - 1)
        occupied = 0
        hasZero = false
    }

    var count: Int { occupied + (hasZero ? 1 : 0) }
    var isEmpty: Bool { count == 0 }

    /// Insert `value`; returns `true` iff it was NOT already present (the
    /// `Set.insert(_:).inserted` contract).
    @inline(__always)
    mutating func insert(_ value: UInt64) -> Bool {
        if value == 0 {
            if hasZero { return false }
            hasZero = true
            return true
        }
        // Grow before insert when load would exceed 0.75 (count*4 >= cap*3).
        if (occupied + 1) &* 4 >= slots.count &* 3 { grow() }
        var i = Int(value & mask)
        while true {
            let s = slots[i]
            if s == 0 {
                slots[i] = value
                occupied += 1
                return true
            }
            if s == value { return false }
            i = Int((UInt64(i) &+ 1) & mask)
        }
    }

    private mutating func grow() {
        let newCap = slots.count << 1
        var newSlots = [UInt64](repeating: 0, count: newCap)
        let newMask = UInt64(newCap - 1)
        for s in slots where s != 0 {
            var i = Int(s & newMask)
            while newSlots[i] != 0 { i = Int((UInt64(i) &+ 1) & newMask) }
            newSlots[i] = s
        }
        slots = newSlots
        mask = newMask
    }
}
