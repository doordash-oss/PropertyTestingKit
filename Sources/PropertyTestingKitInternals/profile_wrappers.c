//
//  profile_wrappers.c
//  PropertyTestingKit
//
//  Exported wrappers for LLVM profile runtime functions.
//  Uses weak_import to link against the profile runtime when available.
//  When coverage is not enabled, these symbols resolve to NULL at runtime.
//

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

// Declare LLVM profile runtime functions with weak_import.
// These will be NULL if coverage instrumentation is not linked.
extern void __llvm_profile_reset_counters(void) __attribute__((weak_import));
extern int __llvm_profile_write_file(void) __attribute__((weak_import));
extern void __llvm_profile_set_filename(const char *) __attribute__((weak_import));
extern int __llvm_profile_dump(void) __attribute__((weak_import));
extern uint64_t *__llvm_profile_begin_counters(void) __attribute__((weak_import));
extern uint64_t *__llvm_profile_end_counters(void) __attribute__((weak_import));
extern const void *__llvm_profile_begin_data(void) __attribute__((weak_import));
extern const void *__llvm_profile_end_data(void) __attribute__((weak_import));

// Availability check - returns 1 if profile runtime is linked
__attribute__((visibility("default")))
int ptk_profile_runtime_available(void) {
    // Check if the weak symbol was resolved
    return &__llvm_profile_reset_counters != NULL;
}

// Exported wrapper functions with predictable names
__attribute__((visibility("default")))
void ptk_profile_reset_counters(void) {
    if (&__llvm_profile_reset_counters != NULL) {
        __llvm_profile_reset_counters();
    }
}

__attribute__((visibility("default")))
int ptk_profile_write_file(void) {
    if (&__llvm_profile_write_file != NULL) {
        return __llvm_profile_write_file();
    }
    return -1;
}

__attribute__((visibility("default")))
void ptk_profile_set_filename(const char *filename) {
    if (&__llvm_profile_set_filename != NULL) {
        __llvm_profile_set_filename(filename);
    }
}

__attribute__((visibility("default")))
int ptk_profile_dump(void) {
    if (&__llvm_profile_dump != NULL) {
        return __llvm_profile_dump();
    }
    return -1;
}

__attribute__((visibility("default")))
uint64_t *ptk_profile_begin_counters(void) {
    if (&__llvm_profile_begin_counters != NULL) {
        return __llvm_profile_begin_counters();
    }
    return NULL;
}

__attribute__((visibility("default")))
uint64_t *ptk_profile_end_counters(void) {
    if (&__llvm_profile_end_counters != NULL) {
        return __llvm_profile_end_counters();
    }
    return NULL;
}

__attribute__((visibility("default")))
const void *ptk_profile_begin_data(void) {
    if (&__llvm_profile_begin_data != NULL) {
        return __llvm_profile_begin_data();
    }
    return NULL;
}

__attribute__((visibility("default")))
const void *ptk_profile_end_data(void) {
    if (&__llvm_profile_end_data != NULL) {
        return __llvm_profile_end_data();
    }
    return NULL;
}
