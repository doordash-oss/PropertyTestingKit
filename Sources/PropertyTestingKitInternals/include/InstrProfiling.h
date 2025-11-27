//
//  InstrProfiling.h
//  PropertyTestingKit
//
//  LLVM Profile Runtime Interface
//
//  These functions are provided by the LLVM profile runtime when code is
//  compiled with coverage instrumentation (-profile-generate or
//  --enable-code-coverage in Swift).
//
//  Reference: https://github.com/llvm/llvm-project/blob/main/compiler-rt/include/profile/InstrProfData.inc
//

#ifndef PROPERTYTESTINGKIT_INSTR_PROFILING_H
#define PROPERTYTESTINGKIT_INSTR_PROFILING_H

#include <stdbool.h>
#include <stdint.h>

#if defined(__cplusplus)
#define PTK_EXTERN extern "C"
#else
#define PTK_EXTERN extern
#endif

#if __has_include(<dlfcn.h>)
#include <dlfcn.h>
#endif

/// Reset all profile counters to zero.
///
/// Call this before running a section of code to isolate its coverage from
/// previously executed code.
///
/// @note This function is only available when coverage instrumentation is
/// enabled. Use ptk_profilerRuntimeAvailable() to check availability.
PTK_EXTERN void __llvm_profile_reset_counters(void);

/// Write the current profile data to the configured file.
///
/// @returns 0 on success, non-zero on failure.
///
/// @note The output filename is determined by the LLVM_PROFILE_FILE environment
/// variable or can be set with __llvm_profile_set_filename().
PTK_EXTERN int __llvm_profile_write_file(void);

/// Set the filename for subsequent profile writes.
///
/// @param filename The path to write profile data to. This string must remain
/// valid until the next call to this function or until the profile is written.
/// Pass NULL to restore the default filename behavior.
PTK_EXTERN void __llvm_profile_set_filename(const char *filename);

/// Write the current profile data and mark it as dumped.
///
/// This function is similar to __llvm_profile_write_file(), but it also marks
/// the profile as "dumped" which prevents the automatic dump that normally
/// occurs at program exit.
///
/// @returns 0 on success, non-zero on failure.
PTK_EXTERN int __llvm_profile_dump(void);

// MARK: - Direct Counter Access

/// Get a pointer to the beginning of the counter array.
///
/// @returns Pointer to the first counter.
PTK_EXTERN uint64_t *__llvm_profile_begin_counters(void);

/// Get a pointer past the end of the counter array.
///
/// @returns Pointer past the last counter.
PTK_EXTERN uint64_t *__llvm_profile_end_counters(void);

/// Get the number of profile counters.
///
/// @returns The total number of counters in the instrumented binary.
PTK_EXTERN uint64_t __llvm_profile_get_num_counters(void);

/// Get the size of counters in bytes.
///
/// @returns The total size of the counter array.
PTK_EXTERN uint64_t __llvm_profile_get_counters_size(void);

// MARK: - Profile Data Records (Per-Function)

/// Profile data record for a single function.
/// This structure matches LLVM's __llvm_profile_data layout.
typedef struct {
    uint64_t NameRef;           // Hash of function name
    uint64_t FuncHash;          // Structural hash of function
    uint64_t *CounterPtr;       // Pointer to this function's counters
    uint64_t *BitmapPtr;        // Pointer to bitmap (for MC/DC)
    void *FunctionPointer;      // Address of the function
    void *Values;               // Value profiling data
    uint32_t NumCounters;       // Number of counters for this function
    uint16_t NumValueSites[8];  // IPVK_Last+1 = 8
    uint32_t NumBitmapBytes;    // Bitmap size
} __llvm_profile_data;

/// Get a pointer to the beginning of the profile data array.
///
/// @returns Pointer to the first profile data record.
PTK_EXTERN const __llvm_profile_data *__llvm_profile_begin_data(void);

/// Get a pointer past the end of the profile data array.
///
/// @returns Pointer past the last profile data record.
PTK_EXTERN const __llvm_profile_data *__llvm_profile_end_data(void);

/// Check if the LLVM profile runtime is available.
///
/// This function uses dlsym to check for the presence of profile runtime
/// symbols. Returns true if coverage instrumentation is available.
///
/// @note This is a runtime check because the profile symbols are only present
/// when the code was compiled with coverage instrumentation.
static inline bool ptk_profilerRuntimeAvailable(void) {
#if __has_include(<dlfcn.h>)
    // Use RTLD_DEFAULT to search all loaded images
#if defined(__APPLE__) || defined(__FreeBSD__) || defined(__OpenBSD__)
    void *handle = (void *)(intptr_t)-2; // RTLD_DEFAULT on Apple/BSD
#elif defined(__linux__) || defined(__ANDROID__)
    void *handle = NULL; // RTLD_DEFAULT on Linux
#else
    void *handle = NULL;
#endif
    return dlsym(handle, "__llvm_profile_reset_counters") != NULL;
#else
    return false;
#endif
}

#endif // PROPERTYTESTINGKIT_INSTR_PROFILING_H
