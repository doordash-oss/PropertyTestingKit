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

/// One input the scheduler decided to run next, tagged as generated vs mutated.
///
/// `poolParentID` is **opaque to the engine** — it never indexes anything with
/// it. `nil` means a freshly generated input; non-`nil` means a mutant. The
/// value is the scheduler's own entry id: the engine uses only the nil/non-nil
/// distinction (to split generated vs mutated `FuzzStats`), but it is kept as an
/// `Int?` rather than a `Bool` on purpose — it's a scheduler-owned lineage tag
/// that observers can use to attribute a mutant to its parent entry. A pool-less
/// scheduler always passes `nil`.
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
/// The engine consults it through three calls:
/// - `next()` — produce the next input to run (generate fresh or mutate one of
///   the scheduler's own retained inputs).
/// - `observe(...)` — report what just ran (the typed input + the per-execution
///   `RawExecutionContext`); the scheduler folds the signals into its own state
///   and working set as it sees fit. It returns nothing: retention is no longer
///   a per-iteration corpus write. The engine names no signal and owns no pool.
/// - `snapshot()` — vend the inputs the scheduler currently retains. The engine
///   calls this ONCE, after the run loop, to build the corpus. The corpus is the
///   scheduler's retained set serialized; it is no longer maintained as the run
///   proceeds, and coverage is no longer a corpus concern.
public struct AnyScheduler<each Input: Codable & Sendable> {
    /// The instrumentation signals this scheduler reads. The engine installs
    /// only these probes, so a scheduler that wants nothing exotic pays for
    /// nothing exotic.
    public let requiredProbes: [any InstrumentationKey.Type]
    /// Produce the next input to run.
    public let next: () -> ScheduledInput<repeat each Input>
    /// Report one executed iteration; the scheduler folds the signals into its
    /// own state. No return: the engine persists nothing per iteration.
    public let observe: ((repeat each Input), RawExecutionContext, SchedulerSource) -> Void
    /// The inputs the scheduler currently retains, vended once at run-end to
    /// build the corpus. A pool-less scheduler returns `[]`.
    public let snapshot: () -> [(repeat each Input)]

    public init(
        requiredProbes: [any InstrumentationKey.Type],
        next: @escaping () -> ScheduledInput<repeat each Input>,
        observe: @escaping ((repeat each Input), RawExecutionContext, SchedulerSource) -> Void,
        snapshot: @escaping () -> [(repeat each Input)]
    ) {
        self.requiredProbes = requiredProbes
        self.next = next
        self.observe = observe
        self.snapshot = snapshot
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

    /// The instrumentation providers this scheduler's signals need, built fresh
    /// per engine. The signal travels WITH the scheduler: a coverage scheduler
    /// vends a coverage provider, a cmp scheduler a cmp provider, a pool-less or
    /// blackbox scheduler none. The engine installs only the providers whose key
    /// some scheduler's `requiredProbes` names, so over-vending is harmless.
    /// Default: no providers (the scheduler reads no instrumentation signal).
    func makeProviders() -> [any InstrumentationProvider]
}

public extension SchedulerFactory {
    func makeProviders() -> [any InstrumentationProvider] { [] }
}
