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

//  Swift per-comparison callbacks for coverage strategies (the trace-cmp half).
//
//  A `ComparisonObserver` is how a strategy expresses per-comparison work in
//  Swift: a value-profile strategy's observer hashes each comparison's
//  (pc, popcount(arg1 ^ arg2)) into a feature set, giving a gradient as an
//  input nears a boundary `i < c` — the signal pure edge coverage is blind to.
//  Like `EdgeObserver`, the observer is attached to a measurement context which
//  CO-OWNS it: retained at attach, released when the context's last reference
//  drops. It rides the INDEPENDENT cmp recorder slot, so a strategy can attach
//  both an edge observer and a comparison observer to the same context.
//
//  This file lives in PropertyTestingKit, which is NOT compiled with
//  -sanitize-coverage — the recorder below fires no comparisons of its own.
//  Comparisons fired by an `onCompare` closure that lives in instrumented code
//  are kept from re-entering it by the SAME per-thread gate edges use
//  (`sancov_observer_enter`): re-entry would deadlock any non-reentrant lock
//  the callback holds.
//

import Foundation
import SanCovHooks

/// A strategy's per-comparison callback (and optional per-iteration reset),
/// called from the cmp-dispatch path for comparisons that route to the context
/// it is attached to.
final class ComparisonObserver: Sendable {
    /// Called for EVERY instrumented comparison that routes to the context:
    /// the comparison site's PC, both operands (zero-extended to 64 bits), and
    /// the operand width in bytes. Because Swift instruments its own runtime
    /// comparisons (refcounts, bounds checks, address compares), a strategy
    /// MUST key on `pc` to isolate the comparisons it cares about from chatter.
    ///
    /// - Important: this runs once per COMPARISON on the hot path — a hot loop
    ///   can call it millions of times per second.
    let onCompare: @Sendable (_ pc: UInt, _ arg1: UInt64, _ arg2: UInt64, _ size: UInt32) -> Void

    /// Called when the context's coverage is reset between iterations, so
    /// per-iteration state (e.g. this run's value-profile feature buffer)
    /// starts each run clean.
    let onReset: (@Sendable () -> Void)?

    init(onCompare: @escaping @Sendable (UInt, UInt64, UInt64, UInt32) -> Void,
         onReset: (@Sendable () -> Void)? = nil) {
        self.onCompare = onCompare
        self.onReset = onReset
    }
}

/// The recorder behind every `ComparisonObserver`: reach the observer box
/// through one acquire load on the context, then call `onCompare` under the
/// shared observer gate. Unlike the edge recorder there is no map to touch —
/// cmp recording is a parallel channel that only delivers operands.
let comparisonObserverRecorder: SanCovCmpRecorder = { pc, arg1, arg2, size, context in
    guard let context else { return }
    guard let data = sancov_context_get_cmp_recorder_data(context) else { return }
    guard sancov_observer_enter() else { return }
    defer { sancov_observer_exit() }
    // `_withUnsafeGuaranteedRef`, not `takeUnretainedValue`: the context CO-OWNS
    // the observer (retained at attach, released only when the context's last
    // reference drops), so while this recorder runs — holding `context` — the
    // observer is provably alive. takeUnretainedValue returns a managed +0
    // reference that the compiler still brackets with a retain/release pair PER
    // COMPARISON (profiled ARC churn, Finding 41d). The guaranteed-ref form tells
    // the optimiser the object can't die for the closure's duration, eliding
    // that pair entirely.
    Unmanaged<ComparisonObserver>.fromOpaque(data)._withUnsafeGuaranteedRef {
        $0.onCompare(pc, arg1, arg2, size)
    }
}

/// Reset hook: forwards `sancov_reset_coverage` to the observer. Shares the
/// observer gate so `onCompare` never runs for comparisons fired by `onReset`.
private let comparisonObserverReset: @convention(c) (UnsafeMutableRawPointer?) -> Void = { data in
    guard let data else { return }
    guard sancov_observer_enter() else { return }
    defer { sancov_observer_exit() }
    // Guaranteed-ref for the same reason as the recorder: the context co-owns
    // the observer and is alive across this call.
    Unmanaged<ComparisonObserver>.fromOpaque(data)._withUnsafeGuaranteedRef {
        $0.onReset?()
    }
}

/// Release hook: balances the attach-time retain when the context drops its
/// last reference (or the recorder is replaced).
private let comparisonObserverRelease: @convention(c) (UnsafeMutableRawPointer?) -> Void = { data in
    guard let data else { return }
    Unmanaged<ComparisonObserver>.fromOpaque(data).release()
}

extension SanCovCounters {
    /// Attach a Swift comparison observer to a measurement context. The context
    /// retains the observer until its own last reference drops — attaching
    /// transfers shared ownership, so the caller may drop the observer (and
    /// everything its closures capture) immediately. Independent of any edge
    /// observer attached to the same context.
    static func attachComparisonObserver(_ observer: ComparisonObserver, to context: MeasurementContext) {
        sancov_context_set_cmp_recorder(
            context.rawContext,
            comparisonObserverRecorder,
            Unmanaged.passRetained(observer).toOpaque(),
            comparisonObserverReset,
            comparisonObserverRelease
        )
    }
}
