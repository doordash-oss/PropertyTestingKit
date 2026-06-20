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

//  FeatureHashSet: an open-addressing UInt64 membership set keyed on the value
//  directly (no Swift Hasher / SipHash). The sign-/comparison-feature novelty
//  oracles store already-splitmix-mixed 64-bit hashes, so re-hashing them with
//  SipHash was pure waste (Finding 41n). It must reproduce Set.insert's
//  `.inserted` contract, including the literal value 0.

import Testing
@testable import PropertyTestingKit

@Suite("Feature hash set")
struct FeatureHashSetTests {

    @Test("insert returns true on first sight, false on repeat")
    func insertOnceThenRepeat() {
        var s = FeatureHashSet()
        #expect(s.insert(0xDEAD_BEEF_CAFE_F00D) == true)
        #expect(s.insert(0xDEAD_BEEF_CAFE_F00D) == false)
    }

    @Test("zero is a valid distinct member (sentinel-safe)")
    func zeroMember() {
        var s = FeatureHashSet()
        #expect(s.isEmpty)
        #expect(s.insert(0) == true)
        #expect(s.insert(0) == false)
        #expect(s.insert(1) == true)   // 1 is distinct from the 0 sentinel slot
        #expect(s.count == 2)
    }

    @Test("distinct values are all new; count tracks them")
    func distinctValues() {
        var s = FeatureHashSet()
        let vals: [UInt64] = [1, 2, 3, 1 << 40, .max, 0xFFFF, 7]
        for v in vals { #expect(s.insert(v) == true) }
        #expect(s.count == vals.count)
        for v in vals { #expect(s.insert(v) == false) }
    }

    @Test("growth past the initial capacity preserves all members")
    func growthPreservesMembers() {
        var s = FeatureHashSet(minimumCapacity: 8)
        // Mixed values, well past the initial capacity to force several rehashes.
        var inserted: [UInt64] = []
        for i in 0..<500 {
            let v = UInt64(i) &* 0x9E37_79B9_7F4A_7C15 ^ 0xABCD
            inserted.append(v)
            #expect(s.insert(v) == true)
        }
        #expect(s.count == 500)
        for v in inserted { #expect(s.insert(v) == false, "member lost across grow: \(v)") }
    }
}
