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
public struct MutationScheduler: Sendable {
    /// Builds a fresh per-engine pool core (fresh policy instances, fresh
    /// state) — same per-engine isolation pattern as `CoverageStrategy`.
    let makeCore: @Sendable () -> WeightedPoolCore

    /// A weighted mutation pool with focus/burst draws.
    ///
    /// - Parameters:
    ///   - admission: Which strategy-accepted inputs join the pool.
    ///   - policies: Child policies built fresh per engine (weight advisors,
    ///     culling, …). Order matters: actions apply in array order.
    ///   - burstLength: Consecutive mutants per focus before the pool owes
    ///     one fresh generation and redraws.
    ///   - focusOnInsert: Newly admitted entries immediately become the
    ///     focus (the classic burst-on-accept exploit behavior).
    public static func weightedPool(
        admission: PoolAdmission = .everyDiscovery,
        policies: @escaping @Sendable () -> [any PoolPlugin] = { [] },
        burstLength: Int = 16,
        focusOnInsert: Bool = true
    ) -> MutationScheduler {
        MutationScheduler(makeCore: {
            WeightedPoolCore(
                admission: admission,
                policies: policies(),
                burstLength: burstLength,
                focusOnInsert: focusOnInsert
            )
        })
    }
}
