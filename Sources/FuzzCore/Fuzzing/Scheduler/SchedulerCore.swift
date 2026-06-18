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

//  The engine-facing scheduler contract. A scheduler decides what the engine
//  runs next and what it retains, reading whatever signals it needs out of the
//  per-execution `RawExecutionContext`. The engine is blind to those signals
//  AND to how the scheduler organizes its inputs: a scheduler OWNS its working
//  set (a weighted pool, a frontier-branch map à la FOX, or nothing at all) and
//  OWNS input production (generation + mutation, using the engine's mutators).
//  The engine is a thin executor — it asks for the next input, runs it, and
//  reports the outcome. Coverage-driven pools, branch-distance schedulers, and
//  anything not yet imagined all plug in from a module that only imports
//  PropertyTestingKit.
//

/// One input the scheduler decided to run next, plus an opaque lineage tag.
///
/// `poolParentID` is round-tripped verbatim into the plugin iteration event's
/// `poolParentID` for attribution; it is **opaque to the engine** — the engine
/// never indexes anything with it. `nil` means the scheduler produced a fresh
/// (generated) input with no parent. The tag lives in the scheduler's own id
/// space; a pool-less scheduler always passes `nil`.
public struct ScheduledInput<each Input: Codable & Sendable> {
    public let input: (repeat each Input)
    public let poolParentID: Int?

    public init(input: (repeat each Input), poolParentID: Int?) {
        self.input = (repeat each input)
        self.poolParentID = poolParentID
    }
}

/// Where one executed input came from, as far as the engine knows.
///
/// The engine distinguishes only inputs it supplied itself (seeds, `queueInputs`,
/// bus-plugin bursts) from inputs the scheduler produced via `next`. Any finer
/// lineage (which pool entry a mutant came from) is the scheduler's own concern —
/// it produced the input, so it already knows.
public enum SchedulerSource: Equatable, Sendable {
    /// The engine's residual queue: seeds or `queueInputs`. The scheduler did
    /// not produce this input; it may still choose to retain it.
    case external
    /// Produced by this scheduler's most recent `next()`.
    case scheduled
}

/// The engine-facing scheduler: a value the engine holds and drives, generic
/// over the input pack so it can OWN the typed inputs it schedules.
///
/// Type-erased (a struct of closures) because Swift has no parameterized
/// existential over a parameter pack — the closures capture a concrete
/// per-engine scheduler implementation. Built by a `SchedulerFactory`, one fresh
/// instance per engine, so the captured state needs no synchronization.
///
/// The engine consults it through exactly two calls per iteration:
/// - `next()` — produce the next input to run (generate fresh or mutate one of
///   the scheduler's own retained inputs).
/// - `observe(...)` — report what just ran (the typed input + the per-execution
///   `RawExecutionContext`); the scheduler folds the signals into its state and
///   returns a signature to persist when the input should be retained in the
///   corpus, or `nil` to retain nothing. The scheduler stores the input in its
///   own working set as it sees fit; the engine only persists the corpus entry.
public struct AnyScheduler<each Input: Codable & Sendable> {
    /// The instrumentation signals this scheduler reads. The engine installs
    /// only these probes, so a scheduler that wants nothing exotic pays for
    /// nothing exotic.
    public let requiredProbes: [any InstrumentationKey.Type]
    /// Produce the next input to run.
    public let next: () -> ScheduledInput<repeat each Input>
    /// Report one executed iteration; return the signature to persist if the
    /// input should be retained in the corpus, else `nil`.
    public let observe: ((repeat each Input), RawExecutionContext, SchedulerSource) -> SparseCoverage?

    public init(
        requiredProbes: [any InstrumentationKey.Type],
        next: @escaping () -> ScheduledInput<repeat each Input>,
        observe: @escaping ((repeat each Input), RawExecutionContext, SchedulerSource) -> SparseCoverage?
    ) {
        self.requiredProbes = requiredProbes
        self.next = next
        self.observe = observe
    }
}

/// Builds a fresh per-engine scheduler at the engine's input pack.
///
/// Pack-generic so the produced `AnyScheduler` can own typed inputs — mirrors
/// `CorpusRegistryProtocol.getCorpus<each T>()`. `Sendable` because one factory
/// is shared across parallel engines (each calls `makeScheduler` to get its own
/// scheduler); the produced scheduler is per-engine and not shared.
public protocol SchedulerFactory: Sendable {
    func makeScheduler<each Input: Codable & Sendable>(
        mutators: repeat Mutator<each Input>
    ) -> AnyScheduler<repeat each Input>
}
