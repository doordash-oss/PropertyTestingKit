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

//  Tests for AtomicFeatureSet: the lock-free insert-only UInt64 set that replaces
//  the per-dispatch SyncBox(NSLock) in ComparisonCoverageStrategy.onCompare
//  (Finding 42). Records the distinct value-profile features seen this run.

import Testing
import Foundation
@testable import PropertyTestingKit

@Suite("AtomicFeatureSet")
struct AtomicFeatureSetTests {

    @Test("insert dedups; snapshot is the distinct features")
    func dedups() {
        let set = AtomicFeatureSet()
        set.insert(5); set.insert(5); set.insert(9)
        #expect(Set(set.snapshot()) == [5, 9])
    }

    @Test("feature value 0 is recorded (not the empty-slot sentinel)")
    func zeroRecorded() {
        let set = AtomicFeatureSet()
        set.insert(0); set.insert(0); set.insert(7)
        #expect(Set(set.snapshot()) == [0, 7])
    }

    @Test("reset clears but the set is reusable")
    func resetClears() {
        let set = AtomicFeatureSet()
        set.insert(1); set.insert(0)
        set.reset()
        #expect(set.snapshot().isEmpty)
        set.insert(2)
        #expect(Set(set.snapshot()) == [2])
    }

    @Test("concurrent inserts dedup exactly, no overflow")
    func concurrentInserts() {
        let set = AtomicFeatureSet()
        let distinct = 500

        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            for v in 0..<distinct { set.insert(UInt64(v)) }
        }

        #expect(Set(set.snapshot()) == Set((0..<distinct).map(UInt64.init)))
        #expect(set.didOverflow == false)
    }
}
