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

// PC guard hooks (required but we don't use them for value profiling)
void __sanitizer_cov_trace_pc_guard_init(uint32_t *start, uint32_t *stop) {
    // We use LLVMCoverageKit for edge coverage, so this is a no-op
}

void __sanitizer_cov_trace_pc_guard(uint32_t *guard) {
    // No-op - edge coverage handled elsewhere
}
