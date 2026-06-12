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

//  The per-engine bundle a coverage strategy is built from.
//

/// A strategy's per-engine bundle: the measurement hooks and the decision,
/// sharing one parallel engine's state.
///
/// Isolation is a property of `makeEngine`, not of the bundle: state created
/// *inside* `makeEngine` is engine-isolated because each parallel engine gets
/// its own call. Engines built by the `CoverageStrategy(onEdge:_:)`
/// convenience wrap the SAME closures into every engine, so anything those
/// closures capture IS shared across engines — that form is for stateless
/// hooks.
///
/// The bundle is pure judgement: it never sees the corpus, the typed input,
/// or schedule bytes — which is what lets one strategy value serve any input
/// pack (including schedule fuzzing's extended pack).
public struct CoverageEngine: Sendable {
    /// Called on every hit of edges routing to this engine's measurement
    /// context (see `CoverageStrategy.init(onEdge:_:)` for semantics). The
    /// second parameter is `true` exactly once per edge per iteration — the
    /// first-hit bit the recorder computes anyway — so strategies that gate
    /// on first hits (loop immunity, like `.pathTrie`) get it for free.
    let onEdge: (@Sendable (_ edge: UInt32, _ isFirstHit: Bool) -> Void)?

    /// Called when the engine's coverage resets between iterations, so
    /// per-iteration state starts each run clean.
    let onReset: (@Sendable () -> Void)?

    /// The judgement half: decides per iteration whether the run's coverage
    /// makes the input interesting. The engine records interesting inputs in
    /// the corpus.
    ///
    /// Runs under the same per-thread gate as `onEdge`/`onReset`: edges fired
    /// by `decide`'s own code are recorded in the map but not observed, so
    /// `decide` may live in instrumented code and share locks with `onEdge`.
    let decide: CoverageDecision

    /// The strategy's culling vocabulary for the LAST accepted decision —
    /// the features the mutation pool's ledger accounts ownership over
    /// (`.pathTrie`: sliding k-grams of the ordered first-hit path;
    /// `.hitCountBuckets`: (edge, bucket) pairs). Called only after `decide`
    /// returns `true`, inside the same gated window. `nil` (the default)
    /// means the pool falls back to the covered edge indices.
    let features: (@Sendable () -> [UInt64])?

    public init(
        onEdge: (@Sendable (UInt32, Bool) -> Void)? = nil,
        onReset: (@Sendable () -> Void)? = nil,
        features: (@Sendable () -> [UInt64])? = nil,
        _ decide: @escaping CoverageDecision
    ) {
        self.onEdge = onEdge
        self.onReset = onReset
        self.features = features
        self.decide = decide
    }
}
