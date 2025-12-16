//
//  ValueProfileHooks.c
//  PropertyTestingKit
//
//  Implementation of LLVM sanitizer coverage hooks for value profile guidance.
//

#include "include/ValueProfileHooks.h"
#include <string.h>

// Thread-local storage for comparison records
static _Thread_local VPComparisonRecord vp_records[VP_MAX_RECORDS];
static _Thread_local size_t vp_count = 0;
static _Thread_local bool vp_enabled = false;

// MARK: - Public API

void vp_reset(void) {
    vp_count = 0;
}

size_t vp_get_count(void) {
    return vp_count;
}

const VPComparisonRecord* vp_get_records(void) {
    if (vp_count == 0) return NULL;
    return vp_records;
}

void vp_set_enabled(bool enabled) {
    vp_enabled = enabled;
}

bool vp_is_enabled(void) {
    return vp_enabled;
}

// MARK: - Internal Helpers

static inline uint64_t compute_distance(uint64_t a, uint64_t b) {
    return a > b ? a - b : b - a;
}

static inline void record_comparison(uint64_t arg1, uint64_t arg2, uint8_t size, bool is_const) {
    if (!vp_enabled) return;
    if (vp_count >= VP_MAX_RECORDS) return;

    uint64_t pc = (uint64_t)__builtin_return_address(1); // Caller's caller
    uint64_t distance = compute_distance(arg1, arg2);

    vp_records[vp_count++] = (VPComparisonRecord){
        .pc = pc,
        .arg1 = arg1,
        .arg2 = arg2,
        .distance = distance,
        .size = size,
        .is_const = is_const
    };
}

// MARK: - Sanitizer Coverage Hooks
// These are called by LLVM when -sanitize-coverage=trace-cmp is enabled

// Variable comparisons (both operands runtime values)
void __sanitizer_cov_trace_cmp1(uint8_t arg1, uint8_t arg2) {
    record_comparison(arg1, arg2, 1, false);
}

void __sanitizer_cov_trace_cmp2(uint16_t arg1, uint16_t arg2) {
    record_comparison(arg1, arg2, 2, false);
}

void __sanitizer_cov_trace_cmp4(uint32_t arg1, uint32_t arg2) {
    record_comparison(arg1, arg2, 4, false);
}

void __sanitizer_cov_trace_cmp8(uint64_t arg1, uint64_t arg2) {
    record_comparison(arg1, arg2, 8, false);
}

// Constant comparisons (one operand is compile-time constant)
void __sanitizer_cov_trace_const_cmp1(uint8_t arg1, uint8_t arg2) {
    record_comparison(arg1, arg2, 1, true);
}

void __sanitizer_cov_trace_const_cmp2(uint16_t arg1, uint16_t arg2) {
    record_comparison(arg1, arg2, 2, true);
}

void __sanitizer_cov_trace_const_cmp4(uint32_t arg1, uint32_t arg2) {
    record_comparison(arg1, arg2, 4, true);
}

void __sanitizer_cov_trace_const_cmp8(uint64_t arg1, uint64_t arg2) {
    record_comparison(arg1, arg2, 8, true);
}

// Switch statement hook
void __sanitizer_cov_trace_switch(uint64_t val, uint64_t *cases) {
    if (!vp_enabled) return;
    if (cases == NULL) return;

    // cases[0] = number of cases
    // cases[1] = size in bits
    // cases[2...] = case values
    uint64_t num_cases = cases[0];

    // Record distance to each case value
    for (uint64_t i = 0; i < num_cases && vp_count < VP_MAX_RECORDS; i++) {
        uint64_t case_val = cases[2 + i];
        record_comparison(val, case_val, 8, true);
    }
}

// MARK: - Thread-Local Coverage Maps (trace_pc_guard)
//
// Swift's -sanitize-coverage=edge uses trace_pc_guard callbacks.
// We maintain thread-local coverage bitmaps that can be reset independently,
// providing TRUE per-test isolation even when tests run concurrently.
//
// This is the key innovation: each thread gets its own coverage bitmap,
// so one test's reset doesn't affect another test's measurements.

#include <stdlib.h>

// Global guard metadata (shared across threads, read-only after init)
static uint32_t *g_guards_start = NULL;
static uint32_t *g_guards_end = NULL;
static size_t g_guard_count = 0;

// Thread-local coverage bitmap - each thread tracks its own coverage
static _Thread_local uint8_t *tls_coverage_map = NULL;
static _Thread_local size_t tls_coverage_map_size = 0;

// Ensure thread-local map is allocated
static void ensure_tls_coverage_map(void) {
    if (tls_coverage_map == NULL && g_guard_count > 0) {
        tls_coverage_map_size = g_guard_count;
        tls_coverage_map = (uint8_t*)calloc(tls_coverage_map_size, 1);
    }
}

// PC guard hooks - used by Swift's -sanitize-coverage=edge
void __sanitizer_cov_trace_pc_guard_init(uint32_t *start, uint32_t *stop) {
    if (g_guards_start == NULL) {
        g_guards_start = start;
        g_guards_end = stop;
        g_guard_count = (size_t)(stop - start);

        // Initialize guards to their index values so we know which edge was hit
        for (uint32_t *p = start; p < stop; p++) {
            *p = (uint32_t)(p - start);
        }
    }
}

void __sanitizer_cov_trace_pc_guard(uint32_t *guard) {
    ensure_tls_coverage_map();
    if (tls_coverage_map && *guard < tls_coverage_map_size) {
        tls_coverage_map[*guard] = 1;
    }
}

// MARK: - Inline 8-bit Counters (alternative instrumentation)
// These are called by LLVM when -sanitize-coverage=inline-8bit-counters is enabled.
// Swift doesn't support this mode directly, but Clang does.

static uint8_t *g_8bit_counters_start = NULL;
static uint8_t *g_8bit_counters_end = NULL;

void __sanitizer_cov_8bit_counters_init(uint8_t *start, uint8_t *end) {
    if (g_8bit_counters_start == NULL) {
        g_8bit_counters_start = start;
        g_8bit_counters_end = end;
    }
}

void __sanitizer_cov_pcs_init(const uintptr_t *pcs_beg, const uintptr_t *pcs_end) {
    (void)pcs_beg;
    (void)pcs_end;
}

// MARK: - Unified Public API
// These functions work with whichever instrumentation mode is active:
// - trace_pc_guard (Swift): Uses thread-local coverage maps
// - inline-8bit-counters (Clang): Uses global counters (no TLS isolation)

bool sancov_counters_available(void) {
    // Either mode provides coverage
    return g_guard_count > 0 ||
           (g_8bit_counters_start != NULL && g_8bit_counters_end != NULL);
}

void sancov_reset_counters(void) {
    // Reset thread-local map (trace_pc_guard mode)
    ensure_tls_coverage_map();
    if (tls_coverage_map) {
        memset(tls_coverage_map, 0, tls_coverage_map_size);
    }

    // Reset global counters (inline-8bit-counters mode)
    if (g_8bit_counters_start && g_8bit_counters_end) {
        memset(g_8bit_counters_start, 0, g_8bit_counters_end - g_8bit_counters_start);
    }
}

size_t sancov_get_counter_count(void) {
    // Prefer trace_pc_guard (has TLS isolation)
    if (g_guard_count > 0) {
        return g_guard_count;
    }
    // Fallback to inline-8bit-counters
    if (g_8bit_counters_start && g_8bit_counters_end) {
        return (size_t)(g_8bit_counters_end - g_8bit_counters_start);
    }
    return 0;
}

size_t sancov_get_covered_count(void) {
    size_t count = 0;

    // Check thread-local map (trace_pc_guard mode)
    ensure_tls_coverage_map();
    if (tls_coverage_map) {
        for (size_t i = 0; i < tls_coverage_map_size; i++) {
            if (tls_coverage_map[i]) count++;
        }
        return count;
    }

    // Fallback to global counters (inline-8bit-counters mode)
    if (g_8bit_counters_start && g_8bit_counters_end) {
        for (uint8_t *p = g_8bit_counters_start; p < g_8bit_counters_end; p++) {
            if (*p != 0) count++;
        }
    }

    return count;
}

const uint8_t* sancov_get_counters(void) {
    // Return thread-local map if available
    ensure_tls_coverage_map();
    if (tls_coverage_map) {
        return tls_coverage_map;
    }
    // Fallback to global counters
    return g_8bit_counters_start;
}

size_t sancov_snapshot_counters(uint8_t* buffer, size_t buffer_size) {
    size_t counter_count = sancov_get_counter_count();
    if (counter_count == 0) return 0;

    // If buffer is NULL, return required size
    if (buffer == NULL) return counter_count;

    const uint8_t* counters = sancov_get_counters();
    if (!counters) return 0;

    // Copy up to buffer_size bytes
    size_t copy_size = buffer_size < counter_count ? buffer_size : counter_count;
    memcpy(buffer, counters, copy_size);
    return copy_size;
}
