//
//  InstrProfiling.h
//  PropertyTestingKit
//
//  LLVM Profile Runtime Interface
//
//  This header provides access to LLVM profile runtime functions through
//  exported wrapper functions. The wrappers are linked with the profile
//  runtime library and export global symbols that work with dlsym.
//

#ifndef PROPERTYTESTINGKIT_INSTR_PROFILING_H
#define PROPERTYTESTINGKIT_INSTR_PROFILING_H

#include <stdbool.h>
#include <stdint.h>
#include <dlfcn.h>

#if defined(__cplusplus)
#define PTK_EXTERN extern "C"
#else
#define PTK_EXTERN extern
#endif

// MARK: - dlsym helpers for wrapper functions

static inline void* ptk_dlsym(const char* name) {
#if defined(__APPLE__)
    return dlsym(RTLD_DEFAULT, name);
#else
    return dlsym(NULL, name);
#endif
}

// MARK: - Availability Check

/// Check if the LLVM profile runtime is available.
/// Returns true if the profile runtime wrappers are linked.
static inline bool ptk_profilerRuntimeAvailable(void) {
    // Check for our exported wrapper function
    return ptk_dlsym("ptk_profile_runtime_available") != NULL;
}

// MARK: - Counter Management Wrappers

static inline void __llvm_profile_reset_counters(void) {
    typedef void (*Fn)(void);
    Fn fn = (Fn)ptk_dlsym("ptk_profile_reset_counters");
    if (fn) fn();
}

static inline int __llvm_profile_write_file(void) {
    typedef int (*Fn)(void);
    Fn fn = (Fn)ptk_dlsym("ptk_profile_write_file");
    return fn ? fn() : -1;
}

static inline void __llvm_profile_set_filename(const char *filename) {
    typedef void (*Fn)(const char*);
    Fn fn = (Fn)ptk_dlsym("ptk_profile_set_filename");
    if (fn) fn(filename);
}

static inline int __llvm_profile_dump(void) {
    typedef int (*Fn)(void);
    Fn fn = (Fn)ptk_dlsym("ptk_profile_dump");
    return fn ? fn() : -1;
}

// MARK: - Direct Counter Access Wrappers

static inline uint64_t *__llvm_profile_begin_counters(void) {
    typedef uint64_t* (*Fn)(void);
    Fn fn = (Fn)ptk_dlsym("ptk_profile_begin_counters");
    return fn ? fn() : NULL;
}

static inline uint64_t *__llvm_profile_end_counters(void) {
    typedef uint64_t* (*Fn)(void);
    Fn fn = (Fn)ptk_dlsym("ptk_profile_end_counters");
    return fn ? fn() : NULL;
}

static inline uint64_t __llvm_profile_get_num_counters(void) {
    uint64_t *begin = __llvm_profile_begin_counters();
    uint64_t *end = __llvm_profile_end_counters();
    if (begin && end && end > begin) {
        return (uint64_t)(end - begin);
    }
    return 0;
}

static inline uint64_t __llvm_profile_get_counters_size(void) {
    return __llvm_profile_get_num_counters() * sizeof(uint64_t);
}

// MARK: - Profile Data Records

typedef struct {
    uint64_t NameRef;
    uint64_t FuncHash;
    uint64_t *CounterPtr;
    uint64_t *BitmapPtr;
    void *FunctionPointer;
    void *Values;
    uint32_t NumCounters;
    uint16_t NumValueSites[8];
    uint32_t NumBitmapBytes;
} __llvm_profile_data;

static inline const __llvm_profile_data *__llvm_profile_begin_data(void) {
    typedef const __llvm_profile_data* (*Fn)(void);
    Fn fn = (Fn)ptk_dlsym("ptk_profile_begin_data");
    return fn ? fn() : NULL;
}

static inline const __llvm_profile_data *__llvm_profile_end_data(void) {
    typedef const __llvm_profile_data* (*Fn)(void);
    Fn fn = (Fn)ptk_dlsym("ptk_profile_end_data");
    return fn ? fn() : NULL;
}

#endif // PROPERTYTESTINGKIT_INSTR_PROFILING_H
