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

//  The extensibility seam between instrumentation and schedulers.
//
//  The engine is blind to what any signal *is*. An instrumentation module
//  defines a `InstrumentationKey` (naming a signal) and a `View` (a typed
//  accessor over that signal's per-execution buffer); a scheduler asks for the
//  view by key. The library enumerates no signals of its own — coverage, cmp
//  traces, timing, and anything not yet imagined are all defined this way, in a
//  module that only imports PropertyTestingKit.
//

/// Names one kind of per-execution instrumentation signal.
///
/// Instrumentation modules declare their own conforming key types; the engine
/// never enumerates them. The associated `View` is a cheap, typed accessor a
/// scheduler reads inside `observe` — see `RawExecutionContext`.
public protocol InstrumentationKey {
    /// A typed accessor over this signal's buffer for the just-finished
    /// execution. Valid only for the duration of the `observe` call that
    /// receives it — a scheduler must fold what it needs into its own state
    /// synchronously rather than stashing the view.
    associatedtype View
}

/// Everything the engine knows about the execution that just finished: a keyed
/// bag of whatever probe views were enabled this run. It names no signal — a
/// scheduler retrieves the views it cares about by key.
///
/// `@unchecked Sendable`: a context is assembled and consumed on a single
/// engine task (the scheduler's `observe` and the synchronous plugin handlers
/// run inline on that task), and the view contract forbids stashing a view past
/// the call that received it. Marked unchecked so it can be embedded in the
/// `Sendable` plugin events — mirroring `FailureFoundContext`. It never actually
/// crosses an isolation boundary.
public struct RawExecutionContext: @unchecked Sendable {
    @usableFromInline
    var views: [ObjectIdentifier: Any]

    /// An empty context. Useful for testing schedulers without a live engine.
    public init() {
        self.views = [:]
    }

    /// Register a probe's view under its key.
    public mutating func set<K: InstrumentationKey>(_ key: K.Type, _ view: K.View) {
        views[ObjectIdentifier(key)] = view
    }

    /// The view for `key`, or `nil` if that probe was not enabled this run.
    @inlinable
    public subscript<K: InstrumentationKey>(_ key: K.Type) -> K.View? {
        views[ObjectIdentifier(key)] as? K.View
    }
}

/// Produces one kind of instrumentation signal for the engine.
///
/// Built fresh per engine (same per-engine isolation as schedulers), so an
/// implementation holds plain mutable state without synchronization. The engine
/// installs a probe only when some active scheduler lists its key in
/// `requiredProbes`, so a run pays for no signal it doesn't consume.
public protocol InstrumentationProbe: AnyObject {
    /// The signal this probe produces.
    associatedtype Key: InstrumentationKey

    /// Install any native instrumentation. Called once before the loop starts.
    func setUp()

    /// Prepare for the next execution (e.g. clear a counter buffer).
    func reset()

    /// Build this execution's view, after the test ran.
    func makeView() -> Key.View

    /// Wrap the whole fuzzing campaign (the engine's loop). The default runs
    /// `body` directly; a probe overrides this to establish a scope that must
    /// span every iteration — e.g. coverage installs a task-local so edges
    /// recorded by child tasks spawned inside the test body are attributed to
    /// this engine's measurement context. The engine nests the scopes of all
    /// installed probes around the loop.
    ///
    /// Declared as a requirement (not just an extension) so the override
    /// dispatches dynamically when the engine holds the probe as `any
    /// InstrumentationProbe`.
    func withCampaignScope(_ body: () async throws -> Void) async rethrows

    /// Tear down native instrumentation. Called once after the loop ends,
    /// after `withCampaignScope` returns. The mirror of `setUp`.
    func tearDown()
}

extension InstrumentationProbe {
    public func setUp() {}
    public func reset() {}
    public func tearDown() {}
    public func withCampaignScope(_ body: () async throws -> Void) async rethrows {
        try await body()
    }

    /// Contribute this probe's view into the per-execution context. Internal:
    /// the engine assembles the context; conformers only implement `makeView`.
    func contribute(to context: inout RawExecutionContext) {
        context.set(Key.self, makeView())
    }
}

/// A probe that accumulates an aggregate index set across the whole run (e.g.
/// the union of every interesting run's covered edges). The engine reads it once
/// at teardown to populate the `.end` event (e.g. coverage-gap analysis) without
/// naming the underlying signal — a probe opts in by conforming.
public protocol AggregateIndexReporting {
    var aggregateIndices: Set<UInt32> { get }
}

/// Supplies a probe to the engine for a signal a scheduler asked for.
///
/// The engine is handed a list of providers (the default list builds the
/// coverage provider; a userspace module can supply its own). For each key in
/// the active scheduler's `requiredProbes`, the engine asks the matching
/// provider to build a fresh probe — so the engine installs probes by matching
/// keys, never by naming any particular signal.
///
/// Not `Sendable`: a provider is built per engine on that engine's own task and
/// never crosses an isolation boundary. (A future API for passing userspace
/// providers into a parallel run would add that constraint then.)
public protocol InstrumentationProvider {
    /// The signal key this provider builds a probe for.
    var key: any InstrumentationKey.Type { get }

    /// Build a fresh probe for one engine. Called once per parallel engine, so
    /// the probe may own unsynchronized per-engine state (including its native
    /// measurement context).
    func makeProbe() -> any InstrumentationProbe
}
