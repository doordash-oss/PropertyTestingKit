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

//  Hooks for LLVM's SanitizerCoverage instrumentation.
//  Provides resettable coverage counters and PC-to-source mapping.
//

#ifndef SANCOV_HOOKS_H
#define SANCOV_HOOKS_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdatomic.h>

#ifdef __cplusplus
extern "C" {
#endif

// MARK: - Inline 8-bit Counters API
// These provide resettable coverage counters via SanitizerCoverage's
// inline-8bit-counters mode. Unlike LLVM's profiling counters, these
// can be safely reset between test executions without breaking Xcode.

/// Check if inline 8-bit counters are available.
/// Returns true if the binary was compiled with -sanitize-coverage=inline-8bit-counters.
bool sancov_counters_available(void);

/// Get the number of instrumented edges (total counter count).
size_t sancov_get_counter_count(void);

/// Get the number of edges that were executed (non-zero counters).
size_t sancov_get_covered_count(void);

/// Get a pointer to the raw counter array.
/// Returns NULL if counters are not available.
/// The array contains sancov_get_counter_count() bytes.
const uint8_t* sancov_get_counters(void);

// MARK: - PC-to-Source Mapping API
// Maps SanCov edge indices to source locations using dladdr.

/// Source location information for a covered edge.
typedef struct {
    const char* filename;      // Source file path (may be NULL)
    const char* function_name; // Demangled function name (may be NULL)
    uintptr_t pc;              // Program counter for this edge
    uintptr_t function_start;  // Function start address from dladdr (dli_saddr)
    uint32_t edge_index;       // The SanCov edge index
} SanCovSourceLocation;

/// Check if PC-to-source mapping is available.
/// Returns true if PCs were captured during initialization.
bool sancov_pcs_available(void);

/// Get the PC for a given edge index.
/// Returns 0 if the index is out of bounds or PCs not available.
uintptr_t sancov_get_pc(size_t edge_index);

/// Get source location info for a given edge index.
/// Fills in the provided location struct.
/// Returns true if successful, false if index out of bounds or PCs unavailable.
/// Note: filename and function_name point to static storage and must not be freed.
bool sancov_get_source_location(size_t edge_index, SanCovSourceLocation* location);

/// Get the number of dladdr calls made (for profiling).
size_t sancov_get_dladdr_call_count(void);

/// Reset the dladdr call counter.
void sancov_reset_dladdr_call_count(void);

/// Get source locations for multiple edge indices (batch version).
/// Much faster than calling sancov_get_source_location in a loop.
/// @param edge_indices Array of edge indices to look up
/// @param locations Output array of source locations (must be same size as edge_indices)
/// @param count Number of edges to look up
/// @return Number of locations successfully filled
size_t sancov_get_source_locations_batch(const size_t* edge_indices, SanCovSourceLocation* locations, size_t count);

/// Get source locations for all covered edges in the current task.
/// Fills the provided array with location info for covered edges.
/// Returns the number of locations written (up to max_locations).
/// If locations is NULL, returns the number of covered edges.
size_t sancov_get_covered_locations(SanCovSourceLocation* locations, size_t max_locations);

// MARK: - Measurement Context API
// Provides isolation for synchronous code measurements.
// When a measurement context is active, coverage is keyed by the context
// rather than the Swift task or thread, providing true per-measurement isolation.

/// Measurement context for coverage isolation.
/// Uses atomic reference counting to prevent use-after-free when TLS caches
/// hold references across thread hops in the worker pool model.
typedef struct {
    uint8_t* coverage_map;
    size_t covered_count;
    _Atomic int refcount;
    /// Per-context generation tag, assigned at begin_measurement. Packed into
    /// the inheritance handle's high bits so a stale task-local handle whose
    /// raw address was recycled by a later, unrelated context is rejected
    /// (closes ABA cross-measurement contamination). See sancov_inheritance_handle.
    uint16_t generation;
    /// Ring buffer of covered edge indices, appended on first-hit.
    /// Enables O(covered_edges) hash/snapshot instead of O(total_edges) scan.
    uint32_t* covered_indices;
    size_t covered_indices_capacity;
    /// Optional per-context edge recorder, stored as pointer bits (the __atomic
    /// builtins reject a function-pointer _Atomic directly; cast on store/load).
    /// 0 → the default recorder. Set by the coverage strategy's setup phase via
    /// sancov_context_set_recorder; read per edge by sancov_dispatch_edge after
    /// routing resolves this context. Severed (fn + reset only) by
    /// sancov_end_measurement so straggler tasks that retain the context past
    /// `end` fall back to the default recorder.
    uintptr_t edge_recorder_bits;
    /// Opaque state for the recorder (e.g. a Swift edge-observer box). Stored/
    /// loaded with release/acquire ordering paired with edge_recorder_bits:
    /// data is written before the fn, so a dispatcher that observes the fn
    /// observes the data. CO-OWNED by the context when a release fn is given:
    /// the context calls recorder_release_bits(recorder_data) when its last
    /// reference drops (or when the recorder is replaced), so any thread that
    /// can still dispatch — every TLS cache holds a context ref — keeps the
    /// data alive. No attacher-side lifetime contract remains.
    void* recorder_data;
    /// Optional `void (*)(void* data)` (as pointer bits) invoked by
    /// sancov_reset_coverage with recorder_data, so per-iteration recorder
    /// state (e.g. a path-trie cursor) resets with the coverage map.
    uintptr_t recorder_reset_bits;
    /// Optional `void (*)(void* data)` (as pointer bits) invoked exactly once
    /// with recorder_data when the context is finally freed, or immediately
    /// when the recorder is replaced/cleared via sancov_context_set_recorder.
    uintptr_t recorder_release_bits;
} SanCovMeasurementContext;

/// Begin a measurement context for coverage isolation.
/// Coverage recorded while a context is active will be isolated to that context.
SanCovMeasurementContext* sancov_begin_measurement(void);

/// End a measurement context and clean up its resources.
void sancov_end_measurement(SanCovMeasurementContext* context);

/// Reset coverage for a measurement context.
/// This zeros the coverage map with memset (cheap) and resets covered_count.
/// Use this between iterations instead of end+begin to avoid hash table overhead.
void sancov_reset_coverage(SanCovMeasurementContext* context);

/// Create a dummy measurement context for testing purposes.
/// The returned context is not registered with any task and should only be used with mocks.
/// Caller is responsible for freeing the returned pointer.
SanCovMeasurementContext* sancov_create_dummy_context(void);

/// TESTING ONLY: drop a context from the active-inheritance liveness set WITHOUT
/// ending/freeing it. Lets a test reproduce the "straggler routes into an ended
/// measurement" scenario deterministically: after this call the liveness gate
/// treats `context` as ended (so inherited edges must fall back), yet the context
/// memory stays valid so the test can read its coverage via
/// `sancov_get_covered_count_with_context`. Pair with `sancov_end_measurement`
/// for cleanup.
void sancov_unregister_inheritance_for_testing(SanCovMeasurementContext* context);

/// TESTING ONLY: drop the CURRENT task's measurement-registry entry WITHOUT
/// touching the active-inheritance liveness set or freeing any context. Lets a
/// test stop the owning task from self-routing into a context (so its own
/// instrumented edges don't inflate that context's coverage) while keeping the
/// context live and active for inheritance-routing assertions.
void sancov_remove_task_measurement_for_testing(void);

/// TESTING ONLY: drop one reference from a context (mirrors the internal
/// refcount release used by sancov_end_measurement), freeing it when the count
/// reaches zero.
void sancov_release_for_testing(SanCovMeasurementContext* context);

/// TESTING ONLY: take an extra reference on a context, standing in for a
/// straggler child task. Lets a test read the context's fields after
/// sancov_end_measurement without use-after-free. Pair with
/// sancov_release_for_testing.
void sancov_retain_for_testing(SanCovMeasurementContext* context);

/// TESTING ONLY: read the context's recorder as raw pointer bits (NULL when the
/// default recorder is in effect).
void* sancov_context_get_recorder_for_testing(SanCovMeasurementContext* context);

/// Read the context's opaque recorder data (acquire). Hot-path safe: used by
/// Swift observer recorders to reach their box; NULL when nothing is attached.
void* sancov_context_get_recorder_data(SanCovMeasurementContext* context);

/// The coverage-inheritance handle for a measurement context: a 64-bit value
/// that packs the context's generation tag (high 16 bits) with its pointer
/// (low 48 bits). Store THIS in the `CoverageInheritance.context` task-local
/// (never the raw pointer): routing decodes the pointer to find the context and
/// verifies the generation, so a stale handle whose address was recycled by a
/// later context no longer aliases it. Aborts if the context pointer does not
/// fit in 48 bits (unexpected on the supported arm64/x86_64 targets).
uint64_t sancov_inheritance_handle(SanCovMeasurementContext* context);

/// Get the number of covered edges for a measurement context (O(1)).
size_t sancov_get_covered_count_with_context(SanCovMeasurementContext* context);

/// Allocate and fill an array of covered edge indices.
/// Returns a newly allocated array that the caller must free().
/// Returns NULL if context is NULL or no edges are covered.
/// Use sancov_get_covered_count_with_context() to get the array size.
uint32_t* sancov_snapshot_covered_indices_with_context(SanCovMeasurementContext* context);

/// Compute signature hash from coverage data without allocation.
/// This matches the SparseCoverage.signatureHash algorithm:
///   hash = XOR of (index * 0x9e3779b97f4a7c15) for each covered index
///   hash ^= count * 0x517cc1b727220a95
///
/// @param context The measurement context to compute hash from
/// @return The signature hash, or 0 if no coverage
int64_t sancov_compute_signature_hash(SanCovMeasurementContext* context);

/// Compute signature hash from an explicit array of edge indices.
/// Pure function — no dependency on live coverage counters.
/// Uses the same algorithm as sancov_compute_signature_hash.
///
/// @param indices Array of edge indices
/// @param count Number of indices
/// @return The signature hash, or 0 if count is 0
int64_t sancov_compute_hash_from_indices(const uint32_t* indices, size_t count);

/// Get a pointer to the covered indices buffer (zero-copy).
/// Valid until the next resetCoverage or endMeasurement call.
/// Returns NULL if no coverage or no buffer.
/// Sets *out_count to the number of covered indices.
const uint32_t* sancov_get_covered_indices(SanCovMeasurementContext* context, size_t* out_count);

/// Merge coverage from a measurement context directly into a bitmap.
/// This is the fast path for checking coverage uniqueness - no allocation needed.
///
/// For each covered edge in the context:
/// - Check if the corresponding bit is set in the bitmap
/// - If not set, set it and return true immediately (new coverage found)
/// - If all edges are already in the bitmap, return false
///
/// If `merge_all` is true, continues merging all edges even after finding new coverage,
/// and returns true if ANY new coverage was found.
///
/// @param context The measurement context to read coverage from
/// @param bitmap The bitmap to merge into (array of uint64_t words)
/// @param bitmap_word_count Number of uint64_t words in the bitmap
/// @param merge_all If true, merge all edges; if false, return early on first new edge
/// @return true if any new coverage was found, false otherwise
bool sancov_merge_coverage_into_bitmap(
    SanCovMeasurementContext* context,
    uint64_t* bitmap,
    size_t bitmap_word_count,
    bool merge_all
);

// MARK: - Edge Recorders
//
// An edge recorder is the *measurement* half of a coverage strategy: what each
// edge hit writes (map cells, covered_indices, observer callbacks, ...). The recorder
// choice lives on the measurement context (edge_recorder_bits), NOT in a
// process-global — so concurrent tests/engines with different strategies never
// stomp each other. __sanitizer_cov_trace_pc_guard resolves routing once and
// dispatches to the context's recorder via sancov_dispatch_edge.

/// An edge recorder. Receives the guard pointer plus the already-resolved
/// coverage map and measurement context (may be NULL on the no-measurement TLS
/// fallback path), so recorders never re-run routing on the hot path.
typedef void (*SanCovEdgeRecorder)(uint32_t* guard, uint8_t* map, SanCovMeasurementContext* context);

/// A recorder-data lifecycle hook: reset (per-iteration state) or release
/// (final ownership drop). Receives the context's recorder_data.
typedef void (*SanCovRecorderDataFn)(void* data);

/// The default recorder: binary first-hit (atomic 0→1) + covered_indices append.
void sancov_recorder_default(uint32_t* guard, uint8_t* map, SanCovMeasurementContext* context);

/// Counting recorder: first hit like the default (map 1 + index append),
/// subsequent hits increment an 8-bit saturating counter up to 255. Enables
/// hit-count bucketing strategies (libFuzzer-style).
void sancov_recorder_counting(uint32_t* guard, uint8_t* map, SanCovMeasurementContext* context);

/// Set (or with NULL clear) the context's edge recorder, its opaque state, and
/// the state's lifecycle hooks. Stores data/hooks before fn (release) so a
/// dispatcher that observes the fn (acquire) observes everything it needs.
///
/// `release`, when non-NULL, transfers ownership of `data` to the context:
/// it is called exactly once — when the context's last reference drops,
/// immediately if the recorder is later replaced/cleared by another call
/// here, or immediately if `recorder` is NULL in this same call (a
/// clear-with-payload never silently drops ownership).
/// `reset`, when non-NULL, is called by sancov_reset_coverage with `data`.
///
/// When `release` is NULL, the context takes NO ownership: the attacher must
/// keep `data` alive until the context's last reference drops — note that is
/// later than sancov_end_measurement, which severs the recorder fn but
/// deliberately leaves `data` set for straggler dispatchers.
///
/// Replacing/clearing while edges are actively dispatching is unsupported
/// (the replaced data is released immediately, racing any in-flight reader);
/// strategies attach once during setup, before the first iteration.
void sancov_context_set_recorder(
    SanCovMeasurementContext* context,
    SanCovEdgeRecorder recorder,
    void* data,
    SanCovRecorderDataFn reset,
    SanCovRecorderDataFn release);

/// Record a first hit for `guard` (atomic map 0→1 + covered_indices append)
/// with the standard bounds checks. Returns true iff this call recorded the
/// first hit. Building block for Swift observer recorders: gate per-edge work
/// on the return value to stay loop-immune.
bool sancov_record_edge_first_hit(uint32_t* guard, uint8_t* map, SanCovMeasurementContext* context);

/// Per-thread observer reentrancy gate. An observer callback that lives in
/// instrumented code fires edges of its own, which dispatch back into the
/// recorder ON THE SAME THREAD — without a gate that re-enters the callback
/// (and deadlocks any non-reentrant lock it holds). Enter returns false when
/// this thread is already inside an observer callback; the caller then skips
/// the callback (the edge is still recorded in the map). Pair every
/// successful enter with exit.
bool sancov_observer_enter(void);
void sancov_observer_exit(void);

/// Resolve routing for the current task/thread and run the context's recorder
/// (default recorder when none is attached or no measurement is active).
/// Called by __sanitizer_cov_trace_pc_guard for every recorded edge; public so
/// tests can drive the real dispatch path with synthetic guards.
void sancov_dispatch_edge(uint32_t* guard);

/// Single-argument convenience: resolve routing, then run the DEFAULT recorder.
/// Does NOT dispatch to the context's recorder (so it can never recurse).
void sancov_record_edge(uint32_t *guard);

/// Single-argument convenience: resolve routing, then run the counting recorder.
void sancov_record_edge_counting(uint32_t *guard);

// MARK: - Schedule-Aware Coverage
//
// When schedule fuzzing is active, test code runs in a different Swift task
// from the engine. The target context mechanism bypasses the task-keyed lookup
// and writes coverage directly to a specified measurement context.

/// Set a target measurement context for schedule-aware coverage recording.
/// When non-NULL, the live edge hook routes the calling thread's edges to this
/// context via `get_current_coverage_map` (atomic, same code path as normal
/// recording), bypassing the task-keyed lookup. Pass NULL to disable.
void sancov_set_target_context(SanCovMeasurementContext* context);

// MARK: - Coverage Inheritance (Task-Local Propagation)

/// Set the task-local key used for coverage inheritance lookup.
void sancov_set_coverage_inheritance_key(const void* key);

/// Get the current Swift task pointer (wraps swift_task_getCurrent).
void* sancov_get_current_task(void);

/// Walk a task's task-local chain to find the key whose value matches expected_value.
const void* sancov_capture_key_by_value(const void* task, uintptr_t expected_value);

/// Scan the bitmap and rebuild covered_indices from it.
/// Call after schedule-controlled drain completes (single-threaded) so that
/// strategies using covered_indices see the correct data.
void sancov_rebuild_covered_indices_from_map(SanCovMeasurementContext* context);

// MARK: - Edge Filter
//
// Filters compiler-generated edges (outlined destroyers, lazy witness table
// accessors, lazy metadata accessors) by setting their guard value to
// SANCOV_GUARD_SKIP. Because the hot-path check is `*guard < g_guard_count`,
// guards set to UINT32_MAX will always fail that check — zero overhead.

/// Sentinel value that disables a guard. Any guard set to this value will be
/// skipped by the edge recording hooks (since UINT32_MAX >= g_guard_count).
#define SANCOV_GUARD_SKIP UINT32_MAX

/// Scan all guard PCs and disable compiler-generated edges.
/// Call once before fuzzing begins — both __sanitizer_cov_trace_pc_guard_init
/// and __sanitizer_cov_pcs_init will have completed by then.
///
/// Filtered symbol patterns (matched on raw mangled dli_sname):
///   - WOh suffix — outlined destroy
///   - WOc suffix — outlined copy
///   - WOd suffix — outlined consume
///   - WOr suffix — outlined release
///   - Wl  suffix — lazy protocol witness table accessor
///   - WL  suffix — lazy metadata accessor
///   - Ma  suffix — type metadata accessor (generic)
///   - __swift_ prefix — runtime internals
///   - _swift_  prefix — runtime internals
void sancov_apply_edge_filter(void);

/// Return the number of edges disabled by sancov_apply_edge_filter().
size_t sancov_get_filtered_count(void);

/// Check if a symbol name matches compiler-generated patterns.
/// Exposed for testing the filter logic.
bool sancov_is_compiler_generated(const char* sname);

/// Diagnostic: per-routing-path counters maintained inside get_current_coverage_map.
/// Pure atomic loads — safe to call from anywhere; concurrent reads are consistent
/// even if increments are interleaved.
typedef struct {
    uint64_t target_ctx;
    uint64_t tls_cache_inheritance_active;
    uint64_t inherited_runtime;
    uint64_t inherited_manualwalk;
    uint64_t per_task_registry;
    uint64_t tls_fallback_inheritance_active;
    uint64_t tls_fallback_no_inheritance;
    /// Sub-categorization of `tls_fallback_inheritance_active`: synchronous
    /// caller (swift_task_getCurrent returned NULL).
    uint64_t tlsfb_sync_pseudo_task;
    /// Sub-categorization: real Swift task whose task-local chain HEAD
    /// (offset 136) is NULL — the task has no inherited locals.
    uint64_t tlsfb_real_task_no_head;
    /// Sub-categorization: real Swift task with non-NULL HEAD whose chain
    /// walk did NOT match the captured key or any registered active
    /// measurement context. This bucket would indicate a routing bug if
    /// non-zero for tasks that should have inherited.
    uint64_t tlsfb_real_task_no_match;
} SanCovRouteCounters;

/// Read the current routing-path counters into `out`. Safe to call concurrently.
void sancov_read_route_counters(SanCovRouteCounters* out);

#ifdef __cplusplus
}
#endif

#endif // SANCOV_HOOKS_H
