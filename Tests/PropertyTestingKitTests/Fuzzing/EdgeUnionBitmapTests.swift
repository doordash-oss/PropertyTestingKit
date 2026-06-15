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

//  EdgeUnionBitmap: the test-and-set edge-coverage union oracle that replaces
//  Set<UInt32> across the coverage strategies (Finding 41m — Set.insert + Hasher
//  was ~7% of the process). It must reproduce Set.insert's `.inserted` contract.

import Testing
@testable import PropertyTestingKit

@Suite("Edge union bitmap")
struct EdgeUnionBitmapTests {

    @Test("insert returns true on first sight, false on repeat")
    func insertOnceThenRepeat() {
        var u = EdgeUnionBitmap()
        #expect(u.insert(7) == true)
        #expect(u.insert(7) == false)
    }

    @Test("distinct edges are all newly inserted; count tracks them")
    func distinctEdges() {
        var u = EdgeUnionBitmap()
        // span multiple 64-bit words (0,1 | 63 | 64,65 | 200)
        for e in [UInt32(0), 1, 63, 64, 65, 200] {
            #expect(u.insert(e) == true)
        }
        #expect(u.count == 6)
        #expect(u.insert(64) == false)
    }

    @Test("empty until first insert")
    func startsEmpty() {
        var u = EdgeUnionBitmap()
        #expect(u.isEmpty)
        _ = u.insert(1000)
        #expect(!u.isEmpty)
        #expect(u.count == 1)
    }

    @Test("a large sparse index grows lazily without losing prior bits")
    func sparseGrowth() {
        var u = EdgeUnionBitmap()
        #expect(u.insert(5) == true)
        #expect(u.insert(100_000) == true)
        #expect(u.insert(5) == false)   // prior bit preserved across the grow
        #expect(u.count == 2)
    }
}
