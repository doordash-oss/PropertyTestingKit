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

//  Tests for the process-global cmp-recorder count that gates sancov_dispatch_cmp:
//  when no measurement context has a comparison recorder attached, the cmp hook
//  must early-return BEFORE the per-thread TLS fetch (Finding 42 follow-up — edge-
//  only strategies were paying ~33M unconsumed cmp-dispatch TLS fetches / 6s).
//
//  The count is process-global, but nothing else in this test target attaches a
//  cmp recorder (the production Swift observer layer isn't running here), so the
//  lifecycle assertions are deterministic. Serialized for belt-and-suspenders.

import Testing
import SanCovHooks

@Suite("SanCov cmp-recorder gate", .serialized)
struct SanCovCmpRecorderGateTests {

    @Test("global cmp-recorder count tracks attach, re-attach, clear, and end_measurement")
    func countTracksLifecycle() {
        guard let ctx = sancov_begin_measurement() else {
            Issue.record("failed to begin measurement")
            return
        }
        let rec: @convention(c) (UInt, UInt64, UInt64, UInt32, UnsafeMutablePointer<SanCovMeasurementContext>?) -> Void = { _, _, _, _, _ in }

        // begin_measurement attaches no cmp recorder.
        #expect(sancov_cmp_recorder_count_for_testing() == 0)

        sancov_context_set_cmp_recorder(ctx, rec, nil, nil, nil)
        #expect(sancov_cmp_recorder_count_for_testing() == 1)

        // Re-attaching to the same context must not double-count.
        sancov_context_set_cmp_recorder(ctx, rec, nil, nil, nil)
        #expect(sancov_cmp_recorder_count_for_testing() == 1)

        // Explicit clear (recorder == nil) drops the count.
        sancov_context_set_cmp_recorder(ctx, nil, nil, nil, nil)
        #expect(sancov_cmp_recorder_count_for_testing() == 0)

        // Re-attach, then end_measurement must also release the count (the sever
        // path, not just the explicit clear).
        sancov_context_set_cmp_recorder(ctx, rec, nil, nil, nil)
        #expect(sancov_cmp_recorder_count_for_testing() == 1)
        sancov_end_measurement(ctx)
        #expect(sancov_cmp_recorder_count_for_testing() == 0)
    }
}
