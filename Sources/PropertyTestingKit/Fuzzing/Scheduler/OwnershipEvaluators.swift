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

//  Ownership evaluators: signal-specific, stateful, they own the ownership
//  *criterion*. Each consumes a run's signal plus the input's size, updates its
//  own metric state, and emits the `Feature`s the run won — for the generic
//  `OwnershipLedger` to record. The metric (edge size, comparison distance)
//  lives here and never reaches the ledger, so adding a new signal is "add an
//  evaluator", not "teach the ledger a new comparison".
//

/// Feature namespaces. Keeps an edge index and a comparison-site `pc` of the
/// same numeric value from colliding in the shared ledger.
enum FeatureDomain {
    static let edge: UInt8 = 0
    static let comparison: UInt8 = 1
}

/// Edge ownership (libFuzzer REDUCE): an edge is owned by the smallest input
/// exhibiting it; ties don't steal, so ownership only ever moves to strictly
/// simpler inputs and the churn terminates. `claims` returns the edges this run
/// won — newly seen, or stolen from a strictly larger owner.
struct EdgeOwnershipEvaluator {
    /// Edge id → smallest owning input's size.
    private var bestSize: [UInt64: Int] = [:]

    mutating func claims(edges: [UInt64], size: Int) -> [Feature] {
        var won: [Feature] = []
        for id in edges {
            if let best = bestSize[id] {
                guard size < best else { continue }   // ties don't steal
            }
            bestSize[id] = size
            won.append(Feature(domain: FeatureDomain.edge, id: id))
        }
        return won
    }
}

/// Boundary-distance ownership (the value-axis gradient): a comparison site
/// (`pc`) is owned by the input that drove its operands closest together
/// (lowest `|arg1 - arg2|`). A strictly closer input steals; on an exact tie the
/// smaller input steals (so ownership prefers the simpler witness). Distance and
/// size both only decrease, so the churn terminates the same way REDUCE does.
struct BoundaryDistanceEvaluator {
    /// Comparison site `pc` → its current owner's (distance, size).
    private var best: [UInt64: (distance: UInt64, size: Int)] = [:]

    mutating func claims(distances: [UInt64: UInt64], size: Int) -> [Feature] {
        var won: [Feature] = []
        for (pc, distance) in distances {
            if let cur = best[pc] {
                let closer = distance < cur.distance
                let tieToSmaller = distance == cur.distance && size < cur.size
                guard closer || tieToSmaller else { continue }
            }
            best[pc] = (distance, size)
            won.append(Feature(domain: FeatureDomain.comparison, id: pc))
        }
        return won
    }
}
