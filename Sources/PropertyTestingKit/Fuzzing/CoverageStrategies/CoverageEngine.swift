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
/// sharing one parallel engine's state. Built fresh by `makeEngine` for each
/// engine, so state captured by these closures never crosses engines.
///
/// The bundle is pure judgement: it never sees the corpus, the typed input,
/// or schedule bytes — which is what lets one strategy value serve any input
/// pack (including schedule fuzzing's extended pack).
public struct CoverageEngine: Sendable {
    /// Called on every hit of edges routing to this engine's measurement
    /// context (see `CoverageStrategy.init(onEdge:_:)` for semantics).
    let onEdge: (@Sendable (UInt32) -> Void)?

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

    public init(
        onEdge: (@Sendable (UInt32) -> Void)? = nil,
        onReset: (@Sendable () -> Void)? = nil,
        _ decide: @escaping CoverageDecision
    ) {
        self.onEdge = onEdge
        self.onReset = onReset
        self.decide = decide
    }
}
