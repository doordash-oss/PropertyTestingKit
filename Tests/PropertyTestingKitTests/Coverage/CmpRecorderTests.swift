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

//  Tests for per-context COMPARISON recorders: the trace-cmp half of the
//  coverage substrate. A comparison recorder lives on the measurement context
//  (cmp_recorder_bits), `sancov_dispatch_cmp` routes each instrumented
//  comparison's operands (pc, arg1, arg2, size) to it, and the slot has the
//  same attach/release/reset lifecycle as the edge recorder. Mirrors
//  ContextRecorderTests for the cmp path.
//

import Testing
import Foundation
import SanCovHooks
@testable import PropertyTestingKit

/// C-ABI capture struct: a `@convention(c)` recorder can't capture, so it
/// reaches its state through the context's cmp recorder data.
private struct CmpCapture {
    var count: Int = 0
    var lastPC: UInt = 0
    var lastArg1: UInt64 = 0
    var lastArg2: UInt64 = 0
    var lastSize: UInt32 = 0
}

/// A recorder that records the last operands it saw into its `CmpCapture` data.
private let captureRecorder: SanCovCmpRecorder = { pc, arg1, arg2, size, ctx in
    guard let ctx, let data = sancov_context_get_cmp_recorder_data(ctx) else { return }
    let p = data.assumingMemoryBound(to: CmpCapture.self)
    p.pointee.count += 1
    p.pointee.lastPC = pc
    p.pointee.lastArg1 = arg1
    p.pointee.lastArg2 = arg2
    p.pointee.lastSize = size
}

/// Raw pointer bits of a cmp recorder, for comparing against the getter seam.
private func cmpRecorderBits(_ hook: SanCovCmpRecorder) -> UnsafeMutableRawPointer {
    unsafeBitCast(hook, to: UnsafeMutableRawPointer.self)
}

@Suite("Per-context comparison recorders")
struct CmpRecorderTests {

    // MARK: - Attach / getter round-trip (no routing involved)

    @Test("Attaching a cmp recorder stores it and its data on the context")
    func attachRoundTrip() {
        let ctx = sancov_create_dummy_context()
        defer { sancov_release_for_testing(ctx) }

        #expect(sancov_context_get_cmp_recorder_for_testing(ctx) == nil,
                "A fresh context has no cmp recorder")

        var capture = CmpCapture()
        withUnsafeMutablePointer(to: &capture) { data in
            sancov_context_set_cmp_recorder(ctx, captureRecorder, UnsafeMutableRawPointer(data), nil, nil)
            #expect(sancov_context_get_cmp_recorder_for_testing(ctx) == cmpRecorderBits(captureRecorder))
            #expect(sancov_context_get_cmp_recorder_data(ctx) == UnsafeMutableRawPointer(data))

            sancov_context_set_cmp_recorder(ctx, nil, nil, nil, nil)
            #expect(sancov_context_get_cmp_recorder_for_testing(ctx) == nil)
            #expect(sancov_context_get_cmp_recorder_data(ctx) == nil)
        }
    }

    /// The cmp slot is independent of the edge slot: attaching a cmp recorder
    /// must not touch the edge recorder, and vice versa. The comparisonCoverage
    /// strategy attaches BOTH (edge union + value profile).
    @Test("The cmp recorder slot is independent of the edge recorder slot")
    func cmpAndEdgeSlotsAreIndependent() {
        let ctx = sancov_create_dummy_context()
        defer { sancov_release_for_testing(ctx) }

        var capture = CmpCapture()
        withUnsafeMutablePointer(to: &capture) { data in
            sancov_context_set_recorder(ctx, sancov_recorder_default, nil, nil, nil)
            sancov_context_set_cmp_recorder(ctx, captureRecorder, UnsafeMutableRawPointer(data), nil, nil)

            #expect(sancov_context_get_recorder_for_testing(ctx) != nil,
                    "Attaching a cmp recorder must not clear the edge recorder")
            #expect(sancov_context_get_cmp_recorder_for_testing(ctx) == cmpRecorderBits(captureRecorder))

            sancov_context_set_cmp_recorder(ctx, nil, nil, nil, nil)
            #expect(sancov_context_get_recorder_for_testing(ctx) != nil,
                    "Clearing the cmp recorder must not clear the edge recorder")
        }
    }

    /// The header promises "release is called exactly once" for any
    /// ownership-transferring set call — including the clear-with-payload shape.
    @Test("Clearing the cmp recorder with a payload still releases it exactly once")
    func clearingReleasesPassedPayload() {
        let ctx = sancov_create_dummy_context()
        defer { sancov_release_for_testing(ctx) }

        var releaseCount = 0
        withUnsafeMutablePointer(to: &releaseCount) { counter in
            sancov_context_set_cmp_recorder(
                ctx, nil, UnsafeMutableRawPointer(counter), nil,
                { data in data?.assumingMemoryBound(to: Int.self).pointee += 1 }
            )
        }

        #expect(releaseCount == 1,
                "ownership transferred to a cleared slot is released, not dropped")
        #expect(sancov_context_get_cmp_recorder_data(ctx) == nil)
    }

    // MARK: - Dispatch routes operands to the attached cmp recorder

    @Test("Dispatch routes the comparison operands to the attached recorder")
    func dispatchRoutesOperands() {
        let context = SanCovCounters.beginMeasurement()
        defer { SanCovCounters.endMeasurement(context) }

        var capture = CmpCapture()
        withUnsafeMutablePointer(to: &capture) { data in
            sancov_context_set_cmp_recorder(
                context.rawContext, captureRecorder, UnsafeMutableRawPointer(data), nil, nil)

            sancov_dispatch_cmp(0xBEEF, 4, 5, 8)

            #expect(data.pointee.count == 1, "the recorder fires once per dispatched comparison")
            #expect(data.pointee.lastPC == 0xBEEF)
            #expect(data.pointee.lastArg1 == 4)
            #expect(data.pointee.lastArg2 == 5)
            #expect(data.pointee.lastSize == 8)

            // Detach before the data pointer goes out of scope.
            sancov_context_set_cmp_recorder(context.rawContext, nil, nil, nil, nil)
        }
    }

    @Test("Dispatch with no cmp recorder attached is a harmless no-op")
    func dispatchWithoutRecorderIsNoOp() {
        let context = SanCovCounters.beginMeasurement()
        defer { SanCovCounters.endMeasurement(context) }

        // No recorder attached: must not crash, must record nothing observable.
        sancov_dispatch_cmp(0x1234, 1, 2, 4)
        #expect(sancov_context_get_cmp_recorder_for_testing(context.rawContext) == nil)
    }

    // MARK: - Lifecycle

    @Test("Reset invokes the cmp recorder's reset hook with its data")
    func resetInvokesResetHook() {
        let context = SanCovCounters.beginMeasurement()
        defer { SanCovCounters.endMeasurement(context) }

        var resetCount = 0
        withUnsafeMutablePointer(to: &resetCount) { counter in
            sancov_context_set_cmp_recorder(
                context.rawContext, captureRecorder, UnsafeMutableRawPointer(counter),
                { data in data?.assumingMemoryBound(to: Int.self).pointee += 1 },
                nil)

            SanCovCounters.resetCoverage(context)
            #expect(counter.pointee == 1, "resetCoverage must invoke the cmp recorder's reset hook")

            sancov_context_set_cmp_recorder(context.rawContext, nil, nil, nil, nil)
        }
    }

    @Test("Freeing the context releases the cmp recorder data exactly once")
    func freeReleasesCmpData() {
        let context = SanCovCounters.beginMeasurement()

        let releaseCount = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        releaseCount.initialize(to: 0)
        defer { releaseCount.deallocate() }

        sancov_context_set_cmp_recorder(
            context.rawContext, captureRecorder, UnsafeMutableRawPointer(releaseCount), nil,
            { data in data?.assumingMemoryBound(to: Int.self).pointee += 1 })

        SanCovCounters.endMeasurement(context)
        #expect(releaseCount.pointee == 1,
                "the context's final release must release the cmp recorder data once")
    }
}
