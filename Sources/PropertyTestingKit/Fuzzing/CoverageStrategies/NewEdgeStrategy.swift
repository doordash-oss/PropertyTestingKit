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

//  New edge strategy: any previously-unseen edge is interesting (AFL/libFuzzer).
//

extension CoverageStrategy {
    /// New edge strategy: any previously-unseen edge is interesting (AFL/libFuzzer).
    public static var newEdge: CoverageStrategy {
        CoverageStrategy(makeEngine: { makeNewEdgeEngine() })
    }
}

/// New edge strategy: an input is interesting iff it covered an edge this
/// engine hasn't seen before. The novelty oracle is the STRATEGY's own
/// per-engine state — the corpus stores results, it doesn't judge them.
private func makeNewEdgeEngine() -> CoverageEngine {
    let seen = SyncBox<Set<UInt32>>([])

    return CoverageEngine { sparse in
        seen.update { seenEdges in
            var foundNew = false
            for edge in sparse.indices where seenEdges.insert(edge).inserted {
                foundNew = true
            }
            return foundNew
        }
    }
}
