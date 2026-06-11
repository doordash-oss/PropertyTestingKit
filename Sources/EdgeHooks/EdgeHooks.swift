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
//  This is the LOW-LEVEL surface: a raw `@convention(c)` recorder replaces
//  the map-write semantics wholesale. Strategy-level per-edge work — "call my
//  Swift function when an edge is hit" — does not live here: pass a closure
//  to `CoverageStrategy(onEdge:)` in PropertyTestingKit, which may capture
//  state freely (the `.pathTrie` strategy captures its trie that way).
//
//  The recorder surface (and the raw SanCovHooks C API beneath it) is
//  `package`-scoped: it names C types, has no public attach path, and
//  exporting it would make the C module un-reorganizable public API — with
//  one-liner footguns like sancov_release_for_testing on a live context.
//  Only `PathTrie` (see PathTrie.swift) is public, as part of the
//  custom-strategy recipes.
//

import SanCovHooks

/// The type of an edge recorder.
///
/// A C-compatible function pointer called on every recorded edge from
/// `__sanitizer_cov_trace_pc_guard` (via `sancov_dispatch_edge`). Receives the
/// guard pointer (holding the edge index) plus the already-resolved coverage
/// map and measurement context — `context` is `nil` when no measurement is
/// active. Recorders never re-run routing on the hot path.
///
/// - Important: This runs millions of times per second. Keep it fast.
package typealias EdgeHook = @convention(c) (
    _ guard: UnsafeMutablePointer<UInt32>?,
    _ map: UnsafeMutablePointer<UInt8>?,
    _ context: UnsafeMutablePointer<SanCovMeasurementContext>?
) -> Void
