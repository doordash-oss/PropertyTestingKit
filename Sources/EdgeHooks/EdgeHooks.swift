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
/// wherever edges fire) and is serialized by the C-side trie lock. The
/// end-of-run operations (`isUniquePath`, `markTerminal`, `reset`) are called
/// by the owning evaluator between iterations, never concurrently with each
/// other. `@unchecked` because the synchronization lives in C, invisible to
/// the compiler.
public final class PathTrie: @unchecked Sendable {
    private let raw: OpaquePointer

    public init() {
        raw = sancov_trie_create()
    }

    deinit {
        sancov_trie_destroy(raw)
    }

    /// The opaque pointer to the underlying C trie.
    public var rawPointer: OpaquePointer { raw }

    /// Whether the current path is unique (not seen before).
    public var isUniquePath: Bool {
        sancov_trie_is_unique_path(raw)
    }

    /// Mark the current path as complete (a terminal node in the trie).
    public func markTerminal() {
        sancov_trie_mark_terminal(raw)
    }

    /// Advance the trie for an edge index.
    /// Does NOT touch the coverage map — pure trie operation.
    public func advance(_ edgeIndex: UInt32) {
        sancov_trie_advance(raw, edgeIndex)
    }

    /// Reset to root for the next iteration.
    public func reset() {
        sancov_trie_reset(raw)
    }

    /// Print all terminal paths in the trie to stderr.
    public func dump() {
        sancov_trie_dump(raw)
    }
}
