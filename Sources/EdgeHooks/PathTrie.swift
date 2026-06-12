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

//  The path trie behind the `.pathTrie` coverage strategy.
//

import Foundation

/// A trie that stores all previously-seen execution paths (ordered edge sequences).
///
/// The `.pathTrie` coverage strategy owns one of these and advances it from a
/// Swift per-edge function:
/// ```swift
/// let trie = PathTrie()
/// // per edge hit:        trie.advance(edgeIndex)
/// // after each run:      if trie.markTerminalIfUnique() { /* corpus */ }
/// // between iterations:  trie.reset()
/// ```
/// Thread-safety: `advance` may be called from any thread (edge observers run
/// wherever edges fire); every operation is serialized by a per-instance lock,
/// so separate tries (e.g. parallel engines') never contend with each other.
/// `@unchecked` because the synchronization is a manual lock, invisible to the
/// compiler.
///
/// Pure Swift: this target is uninstrumented, so trie operations running
/// inside an edge observer cannot fire edges of their own.
public final class PathTrie: @unchecked Sendable {
    /// A trie node: one observed edge transition. The path from the root to a
    /// node is an ordered prefix of some run's edge sequence.
    private final class Node {
        var children: [UInt32: Node] = [:]
        var isTerminal = false
    }

    private let lock = NSLock()
    private let root = Node()
    private var current: Node
    /// Set when the current path created a node nothing had visited before —
    /// such a path is unique regardless of terminal marks.
    private var isNovel = false
    /// The current iteration's ordered edge sequence — the trie holds the
    /// SET of seen paths, this holds the one being walked (needed to emit
    /// k-gram features; the trie alone can't be walked upward).
    private var path: [UInt32] = []

    public init() {
        current = root
    }

    /// Judge and mark in ONE critical section: if the current path is unique,
    /// mark it terminal and report `true`.
    ///
    /// A path is unique (not seen before) when it either created a new node,
    /// or ends at a node no previous run terminated on (prefix semantics — a
    /// strict prefix of a known path is still unique).
    ///
    /// Judge-and-mark is deliberately one operation: with separate check and
    /// mark calls, a straggler `advance` (an un-awaited child task's edge)
    /// could move the cursor between them, putting the terminal mark on a
    /// deeper, wrong node.
    public func markTerminalIfUnique() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return judgeAndMark()
    }

    /// Judge-and-mark, additionally collecting the path's sliding k-gram
    /// features (`PathGrams`) when the path is unique — `nil` otherwise.
    ///
    /// Collection lives in the same critical section as the judgement for the
    /// same reason judge-and-mark do: a straggler `advance` between them
    /// would append to the path and hash grams the judgement never saw.
    public func markTerminalIfUnique(collectingGrams gramLength: Int) -> [UInt64]? {
        lock.lock()
        defer { lock.unlock() }
        guard judgeAndMark() else { return nil }
        return PathGrams.features(of: path, gramLength: gramLength)
    }

    /// Callers must hold `lock`.
    private func judgeAndMark() -> Bool {
        guard isNovel || !current.isTerminal else { return false }
        current.isTerminal = true
        return true
    }

    /// Advance the trie for an edge index: follow the existing child, or grow
    /// a new node (which makes the path novel).
    /// Does NOT touch the coverage map — pure trie operation.
    public func advance(_ edgeIndex: UInt32) {
        lock.lock()
        defer { lock.unlock() }
        path.append(edgeIndex)
        if let child = current.children[edgeIndex] {
            current = child
        } else {
            let child = Node()
            current.children[edgeIndex] = child
            current = child
            isNovel = true
        }
    }

    /// Reset to root for the next iteration.
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        current = root
        isNovel = false
        path.removeAll(keepingCapacity: true)
    }
}
