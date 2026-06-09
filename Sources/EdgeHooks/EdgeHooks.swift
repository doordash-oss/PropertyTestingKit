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

//  Uninstrumented Swift target for working with edge recorders.
//
//  This target is NOT compiled with -sanitize-coverage, so functions here
//  won't trigger __sanitizer_cov_trace_pc_guard. This makes it safe to
//  work with edge recorders in pure Swift without infinite recursion.
//
//  An edge recorder is the *measurement* half of a coverage strategy: what
//  each edge hit writes. Recorders are attached to a fuzz engine's measurement
//  context (never installed process-globally), so concurrent tests with
//  different recorders don't interfere.
//
//  This is the LOW-LEVEL surface: a raw `@convention(c)` recorder that
//  replaces the map-write semantics wholesale (e.g. `countingEdgeHook`'s 8-bit
//  saturating counters). Strategy-level per-edge work — "call my Swift
//  function when an edge is hit" — does not live here: pass a closure to
//  `CoverageStrategy(onEdge:)` in PropertyTestingKit, which may capture state
//  freely (the `.pathTrie` strategy captures its trie that way).
//

import Foundation

// Re-exported: the EdgeHook typealias references SanCovMeasurementContext, so
// anyone who can name an EdgeHook needs the C types visible too.
@_exported import SanCovHooks

/// The type of an edge recorder.
///
/// A C-compatible function pointer called on every recorded edge from
/// `__sanitizer_cov_trace_pc_guard` (via `sancov_dispatch_edge`). Receives the
/// guard pointer (holding the edge index) plus the already-resolved coverage
/// map and measurement context — `context` is `nil` when no measurement is
/// active. Recorders never re-run routing on the hot path.
///
/// - Important: This runs millions of times per second. Keep it fast.
public typealias EdgeHook = @convention(c) (
    _ guard: UnsafeMutablePointer<UInt32>?,
    _ map: UnsafeMutablePointer<UInt8>?,
    _ context: UnsafeMutablePointer<SanCovMeasurementContext>?
) -> Void

/// The default recorder. Binary hit recording (first hit -> 1, subsequent
/// skipped) plus covered-indices bookkeeping.
public let defaultEdgeHook: EdgeHook = sancov_recorder_default

/// Counting recorder. Uses 8-bit saturating counters for hit-count bucketing.
/// On first hit records the edge index; subsequent hits increment up to 255.
public let countingEdgeHook: EdgeHook = sancov_recorder_counting

// MARK: - Path Trie

/// A trie that stores all previously-seen execution paths (ordered edge sequences).
///
/// The `.pathTrie` coverage strategy owns one of these and advances it from a
/// Swift per-edge function:
/// ```swift
/// let trie = PathTrie()
/// // per edge hit:        trie.advance(edgeIndex)
/// // after each run:      if trie.isUniquePath { trie.markTerminal() /* corpus */ }
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

    public init() {
        current = root
    }

    /// Whether the current path is unique (not seen before): it either created
    /// a new node, or ends at a node no previous run terminated on (prefix
    /// semantics — a strict prefix of a known path is still unique).
    public var isUniquePath: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isNovel || !current.isTerminal
    }

    /// Mark the current path as complete (a terminal node in the trie).
    public func markTerminal() {
        lock.lock()
        defer { lock.unlock() }
        current.isTerminal = true
    }

    /// Advance the trie for an edge index: follow the existing child, or grow
    /// a new node (which makes the path novel).
    /// Does NOT touch the coverage map — pure trie operation.
    public func advance(_ edgeIndex: UInt32) {
        lock.lock()
        defer { lock.unlock() }
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
    }

    /// Print all terminal paths in the trie to stderr.
    public func dump() {
        lock.lock()
        defer { lock.unlock() }
        var path: [UInt32] = []
        var count = 0
        func walk(_ node: Node) {
            if node.isTerminal {
                count += 1
                FileHandle.standardError.write(Data("[trie] \(path.map(String.init).joined(separator: " -> "))\n".utf8))
            }
            for (edge, child) in node.children.sorted(by: { $0.key < $1.key }) {
                path.append(edge)
                walk(child)
                path.removeLast()
            }
        }
        FileHandle.standardError.write(Data("[trie] dumping all terminal paths:\n".utf8))
        walk(root)
        FileHandle.standardError.write(Data("[trie] total terminal paths: \(count)\n".utf8))
    }
}
