//
//  ValueProfileHooks.c
//  PropertyTestingKit
//
//  Implementation of LLVM sanitizer coverage hooks for value profile guidance.
//

#include "include/ValueProfileHooks.h"
#include <string.h>
#include <dlfcn.h>

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

// MARK: - Task-Based Coverage Maps (trace_pc_guard)
//
// Swift's -sanitize-coverage=edge uses trace_pc_guard callbacks.
// We maintain per-TASK coverage bitmaps that can be reset independently,
// providing TRUE per-test isolation even when tests run concurrently.
//
// Key insight: Swift Testing uses task groups, and tasks can hop between threads.
// Thread-local storage does NOT provide isolation for Swift concurrency.
// Instead, we use swift_task_getCurrent() to key coverage maps by task pointer.
//
// When not in a Swift async context (swift_task_getCurrent() returns NULL),
// we fall back to thread-local storage for compatibility with non-async code.

#include <stdlib.h>
#include <pthread.h>

// Forward declare Swift runtime function
// Returns the current Swift Task pointer, or NULL if not in an async context
extern void* swift_task_getCurrent(void) __attribute__((weak_import));

// Global guard metadata (shared across all tasks/threads, read-only after init)
static uint32_t *g_guards_start = NULL;
static uint32_t *g_guards_end = NULL;
static size_t g_guard_count = 0;

// MARK: - Task-Keyed Coverage Registry

#define MAX_TASK_ENTRIES 512

typedef struct {
    void* task_id;          // Swift task pointer
    uint8_t* coverage_map;  // Coverage bitmap for this task
} TaskCoverageEntry;

// Registry of per-task coverage maps
static TaskCoverageEntry g_task_registry[MAX_TASK_ENTRIES];
static size_t g_task_registry_count = 0;
static pthread_mutex_t g_registry_lock = PTHREAD_MUTEX_INITIALIZER;

// Thread-local fallback for non-async contexts
static _Thread_local uint8_t *tls_coverage_map = NULL;
static _Thread_local size_t tls_coverage_map_size = 0;

// Thread-local measurement context for sync isolation
// When set, this takes priority over swift_task_getCurrent()
static _Thread_local void* tls_measurement_context = NULL;

// Thread-local cache for coverage map lookup.
// Since tasks stay on the same thread within synchronous code blocks,
// we can cache the last-used task's coverage map per-thread.
// This avoids the registry lookup on every edge hit.
static _Thread_local void* tls_cached_context_id = NULL;
static _Thread_local uint8_t* tls_cached_coverage_map = NULL;

// Lock-free lookup for existing task map.
// Returns NULL if not found (caller should use create_task_map_locked).
//
// Safety: This is safe because entries are append-only during normal operation.
// The memory ordering ensures that when we read count=N, all entries 0..N-1
// are fully initialized (map pointer and task_id both valid).
static uint8_t* find_task_map_lockfree(void* task_id) {
    // Read count with acquire semantics - synchronizes with release in creation
    size_t count = __atomic_load_n(&g_task_registry_count, __ATOMIC_ACQUIRE);

    // Search existing entries (all guaranteed fully initialized)
    for (size_t i = 0; i < count; i++) {
        if (g_task_registry[i].task_id == task_id) {
            return g_task_registry[i].coverage_map;
        }
    }

    return NULL;
}

// Locked creation of new task map.
// Called when find_task_map_lockfree returns NULL.
static uint8_t* create_task_map_locked(void* task_id) {
    pthread_mutex_lock(&g_registry_lock);

    // Double-check: another thread might have created it while we waited
    size_t count = g_task_registry_count;
    for (size_t i = 0; i < count; i++) {
        if (g_task_registry[i].task_id == task_id) {
            uint8_t* map = g_task_registry[i].coverage_map;
            pthread_mutex_unlock(&g_registry_lock);
            return map;
        }
    }

    // Create new entry if space available
    if (count < MAX_TASK_ENTRIES && g_guard_count > 0) {
        uint8_t* map = (uint8_t*)calloc(g_guard_count, 1);
        if (map) {
            // Write order matters for lock-free readers:
            // 1. Store map pointer first (entry not yet visible)
            g_task_registry[count].coverage_map = map;
            // 2. Store task_id (entry still not visible, count unchanged)
            g_task_registry[count].task_id = task_id;
            // 3. Increment count with release - makes entry visible to readers
            //    The release ensures steps 1 and 2 are visible before count changes
            __atomic_store_n(&g_task_registry_count, count + 1, __ATOMIC_RELEASE);
        }
        pthread_mutex_unlock(&g_registry_lock);
        return map;
    }

    pthread_mutex_unlock(&g_registry_lock);
    return NULL;
}

// Find or create a coverage map for the given task.
// Uses lock-free lookup on the hot path, only takes lock for creation.
static uint8_t* find_or_create_task_map(void* task_id) {
    // Fast path: lock-free lookup
    uint8_t* map = find_task_map_lockfree(task_id);
    if (map) return map;

    // Slow path: locked creation
    return create_task_map_locked(task_id);
}

// Remove a task map entry and free its memory
static void cleanup_task_map(void* task_id) {
    pthread_mutex_lock(&g_registry_lock);

    for (size_t i = 0; i < g_task_registry_count; i++) {
        if (g_task_registry[i].task_id == task_id) {
            // Free the coverage map
            free(g_task_registry[i].coverage_map);

            // Move last entry to this slot (swap-remove)
            if (i < g_task_registry_count - 1) {
                g_task_registry[i] = g_task_registry[g_task_registry_count - 1];
            }
            g_task_registry_count--;
            break;
        }
    }

    pthread_mutex_unlock(&g_registry_lock);
}

// MARK: - Measurement Context API
// These functions provide isolation for synchronous measurements

void* sancov_begin_measurement(void) {
    // Use a unique address as the context ID
    // We allocate a small amount to get a unique heap address
    void* context = malloc(1);
    tls_measurement_context = context;
    return context;
}

void sancov_end_measurement(void* context) {
    if (tls_measurement_context == context) {
        tls_measurement_context = NULL;
    }
    // Invalidate cache if it was using this context
    // (The context pointer could be reused by a future malloc)
    if (tls_cached_context_id == context) {
        tls_cached_context_id = NULL;
        tls_cached_coverage_map = NULL;
    }
    // Clean up the task registry entry for this context
    cleanup_task_map(context);
    free(context);
}

// Ensure thread-local fallback map is allocated
static void ensure_tls_coverage_map(void) {
    if (tls_coverage_map == NULL && g_guard_count > 0) {
        tls_coverage_map_size = g_guard_count;
        tls_coverage_map = (uint8_t*)calloc(tls_coverage_map_size, 1);
    }
}

// Get the coverage map for the current execution context
// Priority: measurement context > Swift async task > thread-local
//
// Uses thread-local caching to avoid registry lookup on every edge hit.
// Since tasks stay on the same thread within synchronous code blocks,
// the cache hit rate is very high during test execution.
static uint8_t* get_current_coverage_map(void) {
    // Determine the current context ID (measurement context or task)
    void* context_id = tls_measurement_context;
    if (context_id == NULL && swift_task_getCurrent != NULL) {
        context_id = swift_task_getCurrent();
    }

    // Fast path: check thread-local cache
    if (context_id != NULL && context_id == tls_cached_context_id && tls_cached_coverage_map != NULL) {
        return tls_cached_coverage_map;
    }

    // Slow path: lookup or create, then cache
    if (context_id != NULL) {
        uint8_t* map = find_or_create_task_map(context_id);
        if (map != NULL) {
            // Update cache for next call
            tls_cached_context_id = context_id;
            tls_cached_coverage_map = map;
            return map;
        }
        // Registry full - fall through to thread-local fallback
    }

    // Fallback to thread-local storage for non-async contexts or when registry is full
    ensure_tls_coverage_map();
    return tls_coverage_map;
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
    uint8_t* map = get_current_coverage_map();
    if (map && *guard < g_guard_count) {
        map[*guard] = 1;
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

// MARK: - PC Storage for Source Mapping
// Store PCs from __sanitizer_cov_pcs_init for source location lookup

static const uintptr_t *g_pcs_start = NULL;
static const uintptr_t *g_pcs_end = NULL;
static size_t g_pcs_count = 0;

void __sanitizer_cov_pcs_init(const uintptr_t *pcs_beg, const uintptr_t *pcs_end) {
    if (g_pcs_start == NULL) {
        g_pcs_start = pcs_beg;
        g_pcs_end = pcs_end;
        g_pcs_count = (size_t)(pcs_end - pcs_beg) / 2; // Each entry is 2 uintptrs (PC, flags)
    }
}

// MARK: - Unified Public API
// These functions work with whichever instrumentation mode is active:
// - trace_pc_guard (Swift): Uses task-keyed or thread-local coverage maps
// - inline-8bit-counters (Clang): Uses global counters (no isolation)

bool sancov_counters_available(void) {
    // Either mode provides coverage
    return g_guard_count > 0 ||
           (g_8bit_counters_start != NULL && g_8bit_counters_end != NULL);
}

void sancov_reset_counters(void) {
    // Reset the current context's coverage map (task-keyed or thread-local)
    if (g_guard_count > 0) {
        uint8_t* map = get_current_coverage_map();
        if (map) {
            memset(map, 0, g_guard_count);
        }
        return;
    }

    // Fallback: Reset global counters (inline-8bit-counters mode)
    if (g_8bit_counters_start && g_8bit_counters_end) {
        memset(g_8bit_counters_start, 0, g_8bit_counters_end - g_8bit_counters_start);
    }
}

size_t sancov_get_counter_count(void) {
    // Prefer trace_pc_guard (has task/thread isolation)
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

    // Check task-keyed or thread-local map (trace_pc_guard mode)
    if (g_guard_count > 0) {
        uint8_t* map = get_current_coverage_map();
        if (map) {
            for (size_t i = 0; i < g_guard_count; i++) {
                if (map[i]) count++;
            }
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
    // Return task-keyed or thread-local map if available
    if (g_guard_count > 0) {
        return get_current_coverage_map();
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

size_t sancov_snapshot_covered_indices(uint32_t* indices, uint8_t* counts, size_t max_entries) {
    const uint8_t* counters = sancov_get_counters();
    size_t counter_count = sancov_get_counter_count();
    if (!counters || counter_count == 0) return 0;

    // If indices is NULL, just count covered edges
    if (indices == NULL) {
        size_t covered = 0;
        for (size_t i = 0; i < counter_count; i++) {
            if (counters[i] > 0) covered++;
        }
        return covered;
    }

    // Fill arrays with covered indices and their counts
    size_t filled = 0;
    for (size_t i = 0; i < counter_count && filled < max_entries; i++) {
        if (counters[i] > 0) {
            indices[filled] = (uint32_t)i;
            if (counts) counts[filled] = counters[i];
            filled++;
        }
    }
    return filled;
}

// MARK: - PC-to-Source Mapping Implementation

bool sancov_pcs_available(void) {
    return g_pcs_start != NULL && g_pcs_count > 0;
}

uintptr_t sancov_get_pc(size_t edge_index) {
    if (!sancov_pcs_available() || edge_index >= g_pcs_count) {
        return 0;
    }
    // PC table format: pairs of (PC, flags) - we want the PC
    return g_pcs_start[edge_index * 2];
}

bool sancov_get_source_location(size_t edge_index, SanCovSourceLocation* location) {
    if (!location) return false;

    uintptr_t pc = sancov_get_pc(edge_index);
    if (pc == 0) return false;

    location->pc = pc;
    location->edge_index = (uint32_t)edge_index;
    location->filename = NULL;
    location->function_name = NULL;

    // Use dladdr to get symbol info
    Dl_info info;
    if (dladdr((void*)pc, &info)) {
        location->filename = info.dli_fname;
        location->function_name = info.dli_sname;
    }

    return true;
}

size_t sancov_get_covered_locations(SanCovSourceLocation* locations, size_t max_locations) {
    const uint8_t* counters = sancov_get_counters();
    size_t counter_count = sancov_get_counter_count();

    if (!counters || counter_count == 0) return 0;

    size_t covered_count = 0;

    // First pass: count covered edges (or fill array)
    for (size_t i = 0; i < counter_count; i++) {
        if (counters[i] > 0) {
            if (locations != NULL && covered_count < max_locations) {
                sancov_get_source_location(i, &locations[covered_count]);
            }
            covered_count++;
        }
    }

    return covered_count;
}
