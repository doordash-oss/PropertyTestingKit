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

//  Swift per-edge callbacks for coverage strategies.
//
//  An `EdgeObserver` is how a strategy expresses per-edge work in Swift: the
//  `.pathTrie` strategy's observer captures its trie and advances it on each
//  edge; a custom strategy's `onEdge` closure rides the same mechanism. The
//  observer is attached to a measurement context, which CO-OWNS it: the box is
//  retained at attach and released when the context's last reference drops, so
//  nobody has to keep the observer (or what it captures) alive by hand.
//
//  This file lives in PropertyTestingKit, which is NOT compiled with
//  -sanitize-coverage — the recorder below cannot fire edges of its own.
//  Closures provided by instrumented code (a user's test target) DO fire
//  edges; a per-thread gate (`sancov_observer_enter`) keeps those edges from
//  re-entering the callback that fired them — re-entry would deadlock any
//  non-reentrant lock the callback holds. Such edges are still recorded in
//  the coverage map; they just aren't observed.
//

import Foundation
import EdgeHooks
import SanCovHooks

/// A strategy's per-edge callback (and optional per-iteration reset), called
/// from the edge-dispatch hot path for edges that route to the context it is
/// attached to.
final class EdgeObserver: Sendable {
    /// Called on EVERY hit of every edge that routes to the context — including
    /// loop re-executions. Gating (loop immunity, dedup, counting) is the
    /// strategy's decision, not the library's; `.pathTrie` gates itself. Edges
    /// fired by an observer callback itself are recorded but not observed
    /// (per-thread reentrancy gate), so the closure may live in instrumented
    /// code and take locks safely.
    ///
    /// The second parameter is the C layer's first-hit bit: `true` exactly
    /// once per edge per reset window, computed by the recording CAS the hot
    /// path performs anyway — strategies gating on first hits (the trie's
    /// loop immunity) use it instead of recomputing the answer under a lock.
    ///
    /// - Important: this runs once per HIT on the hot path — a hot loop can
    ///   call it millions of times per second.
    let onEdge: @Sendable (_ edge: UInt32, _ isFirstHit: Bool) -> Void

    /// Called when the context's coverage is reset between iterations, so
    /// per-iteration state (e.g. a path-trie cursor) starts each run clean.
    let onReset: (@Sendable () -> Void)?

    init(onEdge: @escaping @Sendable (UInt32, Bool) -> Void, onReset: (@Sendable () -> Void)? = nil) {
        self.onEdge = onEdge
        self.onReset = onReset
    }
}

/// The recorder behind every `EdgeObserver`: default first-hit recording (map
/// bit + covered_indices, so sparse snapshots keep working), then the
/// observer's `onEdge` for EVERY in-range hit. Runs millions of times per
/// second; the observer box is reached through one acquire load on the context.
let edgeObserverRecorder: EdgeHook = { guardPtr, map, context in
    guard let guardPtr, let context else { return }
    // Explicit bounds check: record_edge_first_hit's false conflates "repeat
    // hit" (observed) with "out of range / filtered" (not observed).
    guard guardPtr.pointee < sancov_get_counter_count() else { return }
    // Past the bounds guard, the recording CAS's result is exactly "first
    // hit of this edge since the last reset" — passed to the observer so
    // strategies don't recompute it.
    let isFirstHit = sancov_record_edge_first_hit(guardPtr, map, context)
    guard let data = sancov_context_get_recorder_data(context) else { return }
    guard sancov_observer_enter() else { return }
    defer { sancov_observer_exit() }
    Unmanaged<EdgeObserver>.fromOpaque(data).takeUnretainedValue().onEdge(guardPtr.pointee, isFirstHit)
}

/// Reset hook: forwards `sancov_reset_coverage` to the observer. Shares the
/// observer gate so `onEdge` never runs for edges fired by `onReset` itself.
private let edgeObserverReset: @convention(c) (UnsafeMutableRawPointer?) -> Void = { data in
    guard let data else { return }
    guard sancov_observer_enter() else { return }
    defer { sancov_observer_exit() }
    Unmanaged<EdgeObserver>.fromOpaque(data).takeUnretainedValue().onReset?()
}

/// Release hook: balances the attach-time retain when the context drops its
/// last reference (or the recorder is replaced).
private let edgeObserverRelease: @convention(c) (UnsafeMutableRawPointer?) -> Void = { data in
    guard let data else { return }
    Unmanaged<EdgeObserver>.fromOpaque(data).release()
}

extension SanCovCounters {
    /// Attach a Swift edge observer to a measurement context. The context
    /// retains the observer until its own last reference drops — attaching
    /// transfers shared ownership, so the caller may drop the observer (and
    /// everything its closures capture) immediately.
    static func attachObserver(_ observer: EdgeObserver, to context: MeasurementContext) {
        sancov_context_set_recorder(
            context.rawContext,
            edgeObserverRecorder,
            Unmanaged.passRetained(observer).toOpaque(),
            edgeObserverReset,
            edgeObserverRelease
        )
    }

    /// Attach a path trie as an edge observer using the standard gated trie
    /// hooks (see `makeTrieHooks`).
    static func attachTrie(_ trie: PathTrie, to context: MeasurementContext) {
        let hooks = makeTrieHooks(trie)
        attachObserver(
            EdgeObserver(onEdge: hooks.onEdge, onReset: hooks.onReset),
            to: context
        )
    }
}

// The trie strategy's gated hooks (`makeTrieHooks`) live with the strategy in
// Fuzzing/CoverageStrategies/PathTrieStrategy.swift.
