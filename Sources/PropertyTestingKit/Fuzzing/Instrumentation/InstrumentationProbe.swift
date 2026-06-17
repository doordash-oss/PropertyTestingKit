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
public struct RawExecutionContext {
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
}

extension InstrumentationProbe {
    public func setUp() {}
    public func reset() {}

    /// Contribute this probe's view into the per-execution context. Internal:
    /// the engine assembles the context; conformers only implement `makeView`.
    func contribute(to context: inout RawExecutionContext) {
        context.set(Key.self, makeView())
    }
}
