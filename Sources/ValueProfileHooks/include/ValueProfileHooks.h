//
//  ValueProfileHooks.h
//  PropertyTestingKit
//
//  Hooks for LLVM's comparison tracing sanitizer coverage.
//  Captures comparison operands for value profile guidance.
//

#ifndef VALUE_PROFILE_HOOKS_H
#define VALUE_PROFILE_HOOKS_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// A single comparison record capturing both operands and their distance.
typedef struct {
    uint64_t pc;        // Return address (identifies which comparison)
    uint64_t arg1;      // First operand
    uint64_t arg2;      // Second operand
    uint64_t distance;  // abs(arg1 - arg2)
    uint8_t size;       // Comparison size in bytes (1, 2, 4, or 8)
    bool is_const;      // Whether one operand was a compile-time constant
} VPComparisonRecord;

/// Maximum number of comparisons to record per test execution.
/// This bounds memory usage and focuses on unique comparisons.
#define VP_MAX_RECORDS 4096

/// Reset the comparison log. Call before each test execution.
void vp_reset(void);

/// Get the number of recorded comparisons since last reset.
size_t vp_get_count(void);

/// Get a pointer to the comparison records array.
/// Returns NULL if no comparisons recorded.
/// The returned pointer is valid until the next vp_reset() call.
const VPComparisonRecord* vp_get_records(void);

/// Enable or disable comparison recording.
/// Disabled by default to avoid overhead when not fuzzing.
void vp_set_enabled(bool enabled);

/// Check if recording is enabled.
bool vp_is_enabled(void);

// MARK: - Inline 8-bit Counters API
// These provide resettable coverage counters via SanitizerCoverage's
// inline-8bit-counters mode. Unlike LLVM's profiling counters, these
// can be safely reset between test executions without breaking Xcode.

/// Check if inline 8-bit counters are available.
/// Returns true if the binary was compiled with -sanitize-coverage=inline-8bit-counters.
bool sancov_counters_available(void);

/// Reset all coverage counters to zero.
/// Safe to call even if counters are not available (no-op).
void sancov_reset_counters(void);

/// Get the number of instrumented edges (total counter count).
size_t sancov_get_counter_count(void);

/// Get the number of edges that were executed (non-zero counters).
size_t sancov_get_covered_count(void);

/// Get a pointer to the raw counter array.
/// Returns NULL if counters are not available.
/// The array contains sancov_get_counter_count() bytes.
const uint8_t* sancov_get_counters(void);

/// Copy the current counter state into a user-provided buffer.
/// Returns the number of bytes copied, or 0 if counters unavailable.
/// If buffer is NULL, returns the required buffer size.
size_t sancov_snapshot_counters(uint8_t* buffer, size_t buffer_size);

// MARK: - PC-to-Source Mapping API
// Maps SanCov edge indices to source locations using dladdr.

/// Source location information for a covered edge.
typedef struct {
    const char* filename;      // Source file path (may be NULL)
    const char* function_name; // Demangled function name (may be NULL)
    uintptr_t pc;              // Program counter for this edge
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

/// Get source locations for all covered edges in the current task.
/// Fills the provided array with location info for covered edges.
/// Returns the number of locations written (up to max_locations).
/// If locations is NULL, returns the number of covered edges.
size_t sancov_get_covered_locations(SanCovSourceLocation* locations, size_t max_locations);

// MARK: - Measurement Context API
// Provides isolation for synchronous code measurements.
// When a measurement context is active, coverage is keyed by the context
// rather than the Swift task or thread, providing true per-measurement isolation.

/// Begin a measurement context for synchronous coverage isolation.
/// Returns an opaque context pointer that must be passed to sancov_end_measurement.
/// Coverage recorded while a context is active will be isolated to that context.
/// The context takes priority over Swift task and thread-local coverage maps.
void* sancov_begin_measurement(void);

/// End a measurement context and clean up its resources.
/// This frees the context and removes its coverage map from the registry.
/// Must be called with the same context pointer returned by sancov_begin_measurement.
void sancov_end_measurement(void* context);

#ifdef __cplusplus
}
#endif

#endif // VALUE_PROFILE_HOOKS_H
