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

//  The engine's mutation scheduler: one pool of interesting inputs per
//  engine, owned by the scheduler, shaped by composable child policies.
//

/// Decides which inputs the engine mutates and when it generates fresh ones.
///
/// Every engine has exactly one scheduler (default: `.weightedPool()`). It
/// owns the mutation pool — the inputs eligible for mutation — and is
/// consulted whenever the residual queue (seeds, `queueInputs`, bus-plugin
/// bursts) is empty. The flat `FuzzPlugin` bus stays for observers; mutation
/// scheduling no longer requires a bus plugin.
///
/// Composition happens inside the pool: `PoolAdmission` decides membership,
/// child `PoolPlugin`s advise weights and evictions, and the owner alone
/// decides what runs next. Children hear every membership change the owner
/// applies, whoever caused it.
import FuzzCore

public struct MutationScheduler: SchedulerFactory {
    /// The underlying factory. Wrapping `any SchedulerFactory` (rather than
    /// being one concrete factory) keeps the design's promise that a
    /// `MutationScheduler` can vend any scheduler, not only the weighted pool.
    let factory: any SchedulerFactory

    /// Build this engine's scheduler at its input pack by forwarding to the
    /// wrapped factory. One fresh scheduler per engine (the factory captures the
    /// engine's mutators so the scheduler owns input production).
    public func makeScheduler<each Input: Codable & Sendable>(
        mutators: repeat Mutator<each Input>
    ) -> AnyScheduler<repeat each Input> {
        factory.makeScheduler(mutators: repeat each mutators)
    }

    /// A weighted mutation pool that picks generation vs mutation by a ratio.
    ///
    /// - Parameters:
    ///   - admission: Which strategy-accepted inputs join the pool.
    ///   - policies: Child policies built fresh per engine (weight advisors,
    ///     culling, …). Order matters: actions apply in array order.
    ///   - generationRatio: Probability each step generates a fresh input rather
    ///     than mutating a pool entry — `1` is all generation, `0` is all
    ///     mutation. One input at a time, no bursts. The default `0.1` is an
    ///     interim starting point (≈ the 1-fresh-per-16-mutant rate of the
    ///     previous burst model); it supersedes that model and should be
    ///     re-tuned against the etna benchmarks rather than treated as final.
    ///   - capacity: Residence bound (`nil` = unbounded). Admitting past it
    ///     evicts the lowest-weight resident (ties: largest measured input,
    ///     then newest). The bound decouples how finely the admission
    ///     vocabulary distinguishes inputs from how many of them may stay —
    ///     without it, a fine vocabulary silently raises the population
    ///     ceiling.
    public static func weightedPool(
        admission: PoolAdmission = .featureOwnership,
        policies: @escaping @Sendable () -> [any PoolPlugin] = { [] },
        generationRatio: Double = 0.1,
        capacity: Int? = nil
    ) -> MutationScheduler {
        MutationScheduler(factory: WeightedPoolFactory(
            admission: admission,
            makePolicies: policies,
            generationRatio: generationRatio,
            capacity: capacity
        ))
    }
}
