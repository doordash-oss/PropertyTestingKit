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

#ifdef __cplusplus
}
#endif

#endif // VALUE_PROFILE_HOOKS_H
