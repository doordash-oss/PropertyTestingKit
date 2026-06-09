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

import Foundation
import EdgeHooks

extension CoverageStrategy {
    /// Path trie strategy: ordered-path tracking (A→B→C differs from A→C→B). The default.
    public static var pathTrie: CoverageStrategy<repeat each Input> {
        CoverageStrategy(builtin: .pathTrie, makeEngine: { makePathTrieEngine() })
    }
}

/// Path trie strategy: O(1) per-hit path tracking, O(1) uniqueness check.
///
/// Built through the same per-engine API custom strategies use — the strategy
/// contains its trie as engine state, advanced by its onEdge hook and judged by
/// its decision. The observer mechanism reports every hit; THIS strategy
/// chooses loop immunity (`makeTrieHooks` gates advancement to an edge's first
/// hit per iteration) so loop counts don't lengthen paths. Each parallel
/// engine builds its own trie, so cursors never interleave.
private func makePathTrieEngine<each Input: Codable & Sendable>(
) -> CoverageEngine<repeat each Input> {
    let trie = PathTrie()
    let hooks = makeTrieHooks(trie)

    return CoverageEngine(
        onEdge: hooks.onEdge,
        onReset: hooks.onReset
    ) { sparse, corpus, input, scheduleBytes in
        defer {
            trie.reset()
        }

        guard trie.isUniquePath else {
            return false
        }

        trie.markTerminal()
        corpus.mergeCoverageAndAdd(input: input, scheduleBytes: scheduleBytes, sparse: sparse)
        return true
    }
}

/// The trie strategy's per-engine hooks: an edge's FIRST hit each iteration
/// advances the trie, and coverage resets return both the gate and the cursor
/// to a clean slate. The first-hit gating is the TRIE strategy's own policy
/// (loop immunity: re-executing a loop must not lengthen the path) — the
/// observer mechanism itself reports every hit. Shared by the `.pathTrie`
/// built-in's engine and `SanCovCounters.attachTrie`.
func makeTrieHooks(
    _ trie: PathTrie
) -> (onEdge: @Sendable (UInt32) -> Void, onReset: @Sendable () -> Void) {
    let gate = FirstHitGate()
    return (
        onEdge: { edge in
            if gate.firstHit(edge) { trie.advance(edge) }
        },
        onReset: {
            gate.reset()
            trie.reset()
        }
    )
}

/// Per-iteration first-hit tracker for strategies that choose loop immunity.
/// Lock-protected because edges arrive from any thread (inheriting child
/// tasks); the critical sections run no instrumented code, and the observer
/// reentrancy gate keeps dispatch from ever re-entering while the lock is held.
private final class FirstHitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = Set<UInt32>()

    /// True exactly once per edge between resets.
    func firstHit(_ edge: UInt32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return seen.insert(edge).inserted
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        seen.removeAll()
    }
}
