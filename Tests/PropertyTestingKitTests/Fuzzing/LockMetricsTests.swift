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

//  Tests for the env-gated lock-acquisition metrics (PTK_LOCK_METRICS): used to
//  validate empirically which SyncBox locks sit on the per-dispatch hot path and
//  whether they ever contend. The metric must be off by default and count both
//  total and contended acquisitions when on.

import Testing
import Foundation
@testable import PropertyTestingKit

@Suite("Lock metrics")
struct LockMetricsTests {

    @Test("when enabled, every acquisition is counted (single thread → no contention)")
    func acquisitionsCountedWhenEnabled() {
        let label = "test.acq.\(UUID().uuidString)"
        let box = PropertyTestingKit.SyncBox(0, label: label, forceMetrics: true)
        for _ in 0..<37 { box.update { $0 += 1 } }

        let m = LockMetrics.snapshotForTesting(label)
        #expect(m?.acquisitions == 37)
        #expect(m?.contended == 0)
    }

    @Test("a contended acquisition (lock already held) is counted as contended")
    func contentionIsCounted() {
        let label = "test.contend.\(UUID().uuidString)"
        let box = PropertyTestingKit.SyncBox(0, label: label, forceMetrics: true)

        let holderHasLock = DispatchSemaphore(value: 0)
        let contenderDone = DispatchSemaphore(value: 0)

        let holder = Thread {
            box.update { _ in
                holderHasLock.signal()
                Thread.sleep(forTimeInterval: 0.2)  // hold the lock so the contender's try() fails
            }
        }
        holder.start()
        holderHasLock.wait()

        let contender = Thread {
            box.update { _ in }   // try() fails while holder sleeps → contended++
            contenderDone.signal()
        }
        contender.start()
        contenderDone.wait()

        let m = LockMetrics.snapshotForTesting(label)
        #expect(m?.acquisitions == 2)
        #expect(m?.contended == 1)
    }

    @Test("without forcing, a label opened while disabled records nothing")
    func disabledByDefaultRecordsNothing() {
        let label = "test.disabled.\(UUID().uuidString)"
        let box = PropertyTestingKit.SyncBox(0, label: label)   // forceMetrics defaults false; env unset in tests
        for _ in 0..<10 { box.update { $0 += 1 } }

        #expect(LockMetrics.snapshotForTesting(label) == nil)
    }
}
