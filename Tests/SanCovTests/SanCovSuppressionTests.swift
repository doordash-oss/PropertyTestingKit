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

//  Tests for the per-thread generation guard (sancov_set_dispatch_suppressed):
//  the fuzz loop sets it around input generation/mutation so instrumented SUT
//  code run by the generator is not dispatched/recorded (Finding 41p).

import Testing
import SanCovHooks
import Foundation

@Suite("SanCov Dispatch Suppression")
struct SanCovSuppressionTests {

    @Test("the suppression flag round-trips on the calling thread")
    func flagRoundTrips() {
        #expect(sancov_dispatch_is_suppressed() == false)
        sancov_set_dispatch_suppressed(true)
        #expect(sancov_dispatch_is_suppressed() == true)
        sancov_set_dispatch_suppressed(false)
        #expect(sancov_dispatch_is_suppressed() == false)
    }

    @Test("edges fired while suppressed are not recorded; unsuppressed are")
    func suppressedRecordsNothing() {
        guard sancov_counters_available(), sancov_pcs_available() else { return }
        guard let ctx = sancov_begin_measurement() else {
            Issue.record("Failed to begin measurement")
            return
        }
        defer {
            sancov_set_dispatch_suppressed(false)  // never leak the flag
            sancov_end_measurement(ctx)
        }

        // Suppressed: instrumented work records nothing. Enable suppression
        // FIRST, then reset — so the count reflects only the suppressed exercise,
        // not the test's own edges fired between begin_measurement and here.
        sancov_set_dispatch_suppressed(true)
        sancov_reset_coverage(ctx)
        exerciseInstrumentedCode()
        let suppressed = sancov_get_covered_count_with_context(ctx)

        // Unsuppressed: the same work records coverage.
        sancov_set_dispatch_suppressed(false)
        sancov_reset_coverage(ctx)
        exerciseInstrumentedCode()
        let unsuppressed = sancov_get_covered_count_with_context(ctx)

        #expect(suppressed == 0, "suppressed dispatch should record nothing, got \(suppressed)")
        #expect(unsuppressed > 0, "unsuppressed dispatch should record edges, got \(unsuppressed)")
    }
}

@inline(never)
private func exerciseInstrumentedCode() {
    var acc = 0
    var array = [3, 1, 4, 1, 5, 9, 2, 6]
    array.append(5)
    for v in array where v > 2 {
        acc &+= v * 2
    }
    _ = array.sorted()
    _ = acc
}
