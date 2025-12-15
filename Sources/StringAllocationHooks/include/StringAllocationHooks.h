//
//  StringAllocationHooks.h
//  PropertyTestingKit
//
//  Hooks Swift string creation to capture magic strings at runtime.
//

#ifndef STRING_ALLOCATION_HOOKS_H
#define STRING_ALLOCATION_HOOKS_H

#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Initialize the string allocation hooks.
/// Called automatically on first use, but can be called explicitly.
void sah_initialize(void);

/// Check if string hooks are available (fishhook succeeded).
bool sah_is_available(void);

/// Enable string capture. Strings created while enabled are recorded.
void sah_enable(void);

/// Disable string capture.
void sah_disable(void);

/// Check if capture is currently enabled.
bool sah_is_enabled(void);

/// Clear all captured strings.
void sah_clear(void);

/// Get the number of captured strings.
size_t sah_get_count(void);

/// Get a captured string by index. Returns NULL if index out of bounds.
/// The returned pointer is valid until sah_clear() is called.
const char* sah_get_string(size_t index);

/// Get all captured strings.
/// out_strings should point to an array of at least sah_get_count() pointers.
/// out_count will be set to the number of strings.
void sah_get_all_strings(const char** out_strings, size_t* out_count);

#ifdef __cplusplus
}
#endif

#endif // STRING_ALLOCATION_HOOKS_H
