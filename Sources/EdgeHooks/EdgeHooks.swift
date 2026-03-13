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
