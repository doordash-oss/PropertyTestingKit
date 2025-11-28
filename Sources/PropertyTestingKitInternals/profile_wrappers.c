//
//  profile_wrappers.c
//  PropertyTestingKit
//
//  Exported wrappers for LLVM profile runtime functions.
//  These wrappers directly call the profile runtime functions and export
//  them as global symbols that can be found via dlsym.
//

#include <stdint.h>
#include <stdbool.h>

// Forward declarations for the profile runtime functions
// These are resolved from Swift's profile runtime when coverage is enabled
extern void __llvm_profile_reset_counters_impl(void) __asm__("___llvm_profile_reset_counters");
extern int __llvm_profile_write_file_impl(void) __asm__("___llvm_profile_write_file");
extern void __llvm_profile_set_filename_impl(const char *) __asm__("___llvm_profile_set_filename");
extern int __llvm_profile_dump_impl(void) __asm__("___llvm_profile_dump");
extern uint64_t *__llvm_profile_begin_counters_impl(void) __asm__("___llvm_profile_begin_counters");
extern uint64_t *__llvm_profile_end_counters_impl(void) __asm__("___llvm_profile_end_counters");
extern const void *__llvm_profile_begin_data_impl(void) __asm__("___llvm_profile_begin_data");
extern const void *__llvm_profile_end_data_impl(void) __asm__("___llvm_profile_end_data");

// Exported wrapper functions with predictable names
__attribute__((visibility("default")))
void ptk_profile_reset_counters(void) {
    __llvm_profile_reset_counters_impl();
}

__attribute__((visibility("default")))
int ptk_profile_write_file(void) {
    return __llvm_profile_write_file_impl();
}

__attribute__((visibility("default")))
void ptk_profile_set_filename(const char *filename) {
    __llvm_profile_set_filename_impl(filename);
}

__attribute__((visibility("default")))
int ptk_profile_dump(void) {
    return __llvm_profile_dump_impl();
}

__attribute__((visibility("default")))
uint64_t *ptk_profile_begin_counters(void) {
    return __llvm_profile_begin_counters_impl();
}

__attribute__((visibility("default")))
uint64_t *ptk_profile_end_counters(void) {
    return __llvm_profile_end_counters_impl();
}

__attribute__((visibility("default")))
const void *ptk_profile_begin_data(void) {
    return __llvm_profile_begin_data_impl();
}

__attribute__((visibility("default")))
const void *ptk_profile_end_data(void) {
    return __llvm_profile_end_data_impl();
}

// Availability check - returns 1 if profile runtime is linked
__attribute__((visibility("default")))
int ptk_profile_runtime_available(void) {
    return 1;
}
