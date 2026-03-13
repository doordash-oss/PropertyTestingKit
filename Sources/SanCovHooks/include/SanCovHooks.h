//
//  SanCovHooks.h
//  PropertyTestingKit
//
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

#ifdef __cplusplus
}
#endif

#endif // SANCOV_HOOKS_H
