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

//  The batteries-included default wiring for the signal-agnostic engine: edge
//  coverage + the weighted-pool scheduler. The core `FuzzEngine` takes injected
//  provider/scheduler factories and names no signal; this convenience supplies
//  the defaults most callers want.
//

import FuzzCore
import Dependencies

extension FuzzEngine {
    /// Non-scheduled convenience initializer with the default coverage strategy
    /// (`.pathTrie`) and scheduler (`.weightedPool()`), and a no-op
    /// schedule-bytes extractor.
    convenience init(
        mutators: repeat Mutator<each Input>,
        config: FuzzEngineConfig = FuzzEngineConfig(),
        coverageStrategy: CoverageStrategy = .pathTrie,
        scheduler: any SchedulerFactory = MutationScheduler.weightedPool()
    ) {
        self.init(
            mutators: repeat each mutators,
            config: config,
            makeInstrumentationProviders: {
                @Dependency(\.coverageCounters) var client
                return [CoverageProvider(evaluator: coverageStrategy.makeEvaluator(), client: client)]
            },
            schedulerFactory: scheduler,
            scheduleBytesExtractor: { _ in nil }
        )
    }
}
