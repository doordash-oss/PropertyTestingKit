//
//  EdgeHooks.swift
//  PropertyTestingKit
//
//  Uninstrumented Swift target for writing custom edge hooks.
//
//  This target is NOT compiled with -sanitize-coverage, so functions here
//  won't trigger __sanitizer_cov_trace_pc_guard. This makes it safe to
//  write edge hooks in pure Swift without infinite recursion.
//
//  Users import this module alongside PropertyTestingKit to write custom hooks:
//
//  ```swift
//  import PropertyTestingKit
//  import EdgeHooks
//  import SanCovHooks
//
//  let myHook: EdgeHook = makeEdgeHook { map, edgeIndex, guardCount in
//      // Custom counting logic
//      let prev = map[Int(edgeIndex)]
//      if prev == 0 {
//          map[Int(edgeIndex)] = 1
//          sancov_record_first_hit(edgeIndex)
//      } else if prev < 255 {
//          map[Int(edgeIndex)] = prev &+ 1
//      }
//  }
//  ```
//

import SanCovHooks

/// The type of a coverage edge hook.
///
/// A C-compatible function pointer called on every edge hit from
/// `__sanitizer_cov_trace_pc_guard`. The guard pointer contains the edge index.
///
/// - Important: This runs millions of times per second. Keep it fast.
public typealias EdgeHook = @convention(c) (UnsafeMutablePointer<UInt32>?) -> Void

/// The default edge hook. Binary hit recording (first hit -> 1, subsequent skipped).
public let defaultEdgeHook: EdgeHook = sancov_record_edge

/// Counting edge hook. Uses 8-bit saturating counters for hit-count bucketing.
/// On first hit records the edge index; subsequent hits increment up to 255.
public let countingEdgeHook: EdgeHook = sancov_record_edge_counting

/// Trie edge hook. Records binary coverage AND tracks execution paths in a trie.
/// O(1) per edge hit, O(1) uniqueness check at end of run.
public let trieEdgeHook: EdgeHook = sancov_record_edge_trie

// MARK: - Path Trie

/// A trie that stores all previously-seen execution paths (ordered edge sequences).
///
/// Usage with the trie edge hook:
/// ```swift
/// let trie = PathTrie()
/// trie.activate()
/// SanCovCounters.setEdgeHook(trieEdgeHook)
///
/// // After each test execution:
/// if trie.isUniquePath {
///     trie.markTerminal()
///     // Add to corpus...
/// }
/// trie.reset()
/// ```
public final class PathTrie {
    private let raw: OpaquePointer

    public init() {
        raw = sancov_trie_create()
    }

    deinit {
        sancov_trie_destroy(raw)
    }

    /// The opaque pointer to the underlying C trie.
    /// Used by the coverage strategy to attach this trie to a measurement context.
    public var rawPointer: OpaquePointer { raw }

    /// Attach this trie to a measurement context.
    /// The trie hook will read the trie from the context on every edge hit.
    public func attach(to context: UnsafeMutablePointer<SanCovMeasurementContext>) {
        sancov_context_set_trie(context, raw)
    }

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
}
