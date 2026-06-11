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

//  Path trie strategy: ordered-path tracking. The default strategy, defined
//  through the same public per-engine API as any custom strategy.
//

import EdgeHooks

extension CoverageStrategy {
    /// Path trie strategy: ordered-path tracking (A→B→C differs from A→C→B). The default.
    public static var pathTrie: CoverageStrategy {
        CoverageStrategy(makeEngine: { makePathTrieEngine() })
    }
}

/// Path trie strategy: O(1) per-hit path tracking, O(1) uniqueness check.
///
/// The strategy contains its trie as engine state, advanced by its onEdge hook
/// and judged by its decision (the sparse coverage itself is unused — the path
/// IS the judgement). The observer mechanism reports every hit; THIS strategy
/// chooses loop immunity (`makeTrieHooks` gates advancement to an edge's first
/// hit per iteration) so loop counts don't lengthen paths. Each parallel
/// engine builds its own trie, so cursors never interleave.
private func makePathTrieEngine() -> CoverageEngine {
    let trie = PathTrie()
    let hooks = makeTrieHooks(trie)

    return CoverageEngine(
        onEdge: hooks.onEdge,
        onReset: hooks.onReset
    ) { _ in
        defer {
            trie.reset()
        }

        // One critical section for judge-and-mark: a straggler advance
        // between a separate check and mark would move the cursor and put
        // the terminal mark on the wrong node.
        return trie.markTerminalIfUnique()
    }
}

/// The trie strategy's per-engine hooks: an edge's FIRST hit each iteration
/// advances the trie, and coverage resets return the cursor to a clean
/// slate. The first-hit gating is the TRIE strategy's own policy (loop
/// immunity: re-executing a loop must not lengthen the path) — the observer
/// mechanism reports every hit and hands over the C layer's lock-free
/// first-hit bit, which resets stay synced with (`sancov_reset_coverage`
/// clears the map before invoking `onReset`). Shared by the `.pathTrie`
/// built-in's engine and `SanCovCounters.attachTrie`.
func makeTrieHooks(
    _ trie: PathTrie
) -> (onEdge: @Sendable (UInt32, Bool) -> Void, onReset: @Sendable () -> Void) {
    (
        onEdge: { edge, isFirstHit in
            if isFirstHit { trie.advance(edge) }
        },
        onReset: {
            trie.reset()
        }
    )
}
