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

//  Shared white-box harness for driving a `WeightedPoolCore<Int>` hermetically.
//  The pool's draw/admission policy is input-agnostic, so a stub Int mutator
//  suffices; `accept`/`miss` feed the `admit` seam directly with explicit
//  features and size, the way the engine-facing `observe` would after reading
//  the coverage probe and measuring the input.
//

import FuzzCore
@testable import PropertyTestingKit

enum WeightedPoolHarness {
    /// A trivial Int mutator: production is a no-op stub here.
    static let intMutator = Mutator<Int>(seeds: [0], mutate: { v, _ in v }, generate: { _ in 0 })

    /// A fresh core. `generationRatio: 0` makes every decision with a non-empty
    /// pool a weighted draw, so draw-distribution tests are deterministic.
    static func core(
        admission: PoolAdmission = .everyDiscovery,
        policies: [any PoolPlugin] = [],
        generationRatio: Double = 0,
        capacity: Int? = nil
    ) -> WeightedPoolCore<Int> {
        WeightedPoolCore<Int>(
            mutators: intMutator,
            admission: admission,
            policies: policies,
            generationRatio: generationRatio,
            capacity: capacity,
            rng: FastRNG())
    }

    /// One accepted discovery, shaped like the engine's accept path.
    @discardableResult
    static func accept(
        _ core: WeightedPoolCore<Int>,
        edges: [UInt32],
        features: [UInt64]? = nil,
        inputSize: Int? = nil,
        parent: Int? = nil
    ) -> Int? {
        let source: PoolIterationSource = parent.map { .pool(parent: $0) } ?? .generated
        return core.admit(0, coverage: SparseCoverage(indices: edges),
                          features: features, inputSize: inputSize, poolSource: source)
    }

    /// One uninteresting execution attributed to `parent`.
    static func miss(_ core: WeightedPoolCore<Int>, parent: Int? = nil) {
        let source: PoolIterationSource = parent.map { .pool(parent: $0) } ?? .generated
        _ = core.admit(0, coverage: nil, poolSource: source)
    }
}
