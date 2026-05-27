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
/// Forward declaration for path trie (defined in SanCovHooks.c).
typedef struct SanCovPathTrie SanCovPathTrie;

typedef struct {
    uint8_t* coverage_map;
    size_t covered_count;
    _Atomic int refcount;
    /// Ring buffer of covered edge indices, appended on first-hit.
    /// Enables O(covered_edges) hash/snapshot instead of O(total_edges) scan.
    uint32_t* covered_indices;
    size_t covered_indices_capacity;
    /// Optional path trie for the trie edge hook. Set by the strategy, read by the hook.
    /// NULL when trie tracking is not active.
    SanCovPathTrie* path_trie;
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

/// The default edge recording implementation.
/// Records a binary hit (first-hit writes 1, subsequent skipped) and
/// appends to the covered indices buffer.
void sancov_record_edge(uint32_t *guard);

/// Counting edge recording implementation.
/// Uses 8-bit saturating counters: first hit records the edge index (same as binary),
/// subsequent hits increment the counter up to 255. Enables hit-count bucketing
/// strategies (libFuzzer-style).
void sancov_record_edge_counting(uint32_t *guard);

// MARK: - Trie Edge Hook
//
// O(1)-per-hit path tracking using a trie of edge sequences.
// Each unique execution path (ordered sequence of edge hits) is a path in the trie.
// On each edge hit, the current pointer advances to the child for that edge index.
// If no child exists, a new node is created and a "novel" flag is set.

/// Set the path trie on a measurement context.
/// The trie hook will read from this context's trie pointer.
void sancov_context_set_trie(SanCovMeasurementContext* context, SanCovPathTrie* trie);

/// Create a new path trie.
SanCovPathTrie* sancov_trie_create(void);

/// Destroy a path trie and free all nodes.
void sancov_trie_destroy(SanCovPathTrie* trie);

/// Check if the current path in the trie is unique.
/// Returns true if: the novel flag is set, OR the current node is not terminal.
bool sancov_trie_is_unique_path(SanCovPathTrie* trie);

/// Mark the current node as terminal (end of a complete run).
void sancov_trie_mark_terminal(SanCovPathTrie* trie);

/// Reset the trie pointer to root and clear the novel flag.
void sancov_trie_reset(SanCovPathTrie* trie);

/// Dump all terminal paths in the trie to stderr.
void sancov_trie_dump(SanCovPathTrie* trie);

/// Advance the trie for a given edge index.
/// If the child exists, advance. If not, create child and set novel flag.
/// This is the low-level trie operation — does NOT touch the coverage map.
void sancov_trie_advance(SanCovPathTrie* trie, uint32_t edge_index);

/// Trie edge hook. Records binary coverage AND advances the trie pointer.
/// On each edge hit: if child exists, advance; if not, create child and set novel flag.
/// Both operations are O(1).
void sancov_record_edge_trie(uint32_t *guard);

/// Install a custom hook function that overrides the default Swift trampoline.
/// The hook is a C function pointer called on every edge hit.
/// Pass NULL to restore the default (sancov_swift_trampoline → sancov_record_edge).
void sancov_install_swift_hook(void (*hook)(uint32_t*));

// MARK: - Schedule-Aware Coverage
//
// When schedule fuzzing is active, test code runs in a different Swift task
// from the engine. The target context mechanism bypasses the task-keyed lookup
// and writes coverage directly to a specified measurement context.

/// Set a target measurement context for schedule-aware coverage recording.
/// When non-NULL, `sancov_record_edge_to_target` writes to this context
/// instead of using the task-keyed lookup.
/// Pass NULL to disable.
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

/// Edge recording that writes to the target context set by `sancov_set_target_context`.
/// Falls back to `sancov_record_edge` if no target context is set.
/// Use as the hook via `sancov_install_swift_hook(sancov_record_edge_to_target)`.
void sancov_record_edge_to_target(uint32_t *guard);

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

/// Enable/disable debug logging for trie advances.
void sancov_trie_set_debug(bool enable);

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
