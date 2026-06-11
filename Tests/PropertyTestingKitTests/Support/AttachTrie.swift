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

//  Test seam: the `.pathTrie` strategy's measurement half, attached directly
//  to a measurement context — no engine, no evaluator. Tests drive dispatch
//  themselves and judge paths by hand (markTerminalIfUnique / resetCoverage).
//

@testable import PropertyTestingKit

extension SanCovCounters {
    /// Attach a path trie as an edge observer using the strategy's own gated
    /// hooks (`makeTrieHooks`): advance on first hit per iteration, rewind on
    /// coverage reset.
    static func attachTrie(_ trie: PathTrie, to context: MeasurementContext) {
        let hooks = makeTrieHooks(trie)
        attachObserver(
            EdgeObserver(onEdge: hooks.onEdge, onReset: hooks.onReset),
            to: context
        )
    }
}
