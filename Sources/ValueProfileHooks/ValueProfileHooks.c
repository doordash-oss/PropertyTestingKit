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
#include <stdatomic.h>
#include <pthread.h>  // For measurement context registry (not in hot path)

// Forward declare Swift runtime function
// Returns the current Swift Task pointer, or NULL if not in an async context
extern void* swift_task_getCurrent(void) __attribute__((weak_import));

// Global guard metadata (shared across all tasks/threads, read-only after init)
static uint32_t *g_guards_start = NULL;
static uint32_t *g_guards_end = NULL;
static size_t g_guard_count = 0;

// MARK: - Task-Keyed Coverage Registry (Lock-Free)

#define MAX_TASK_ENTRIES 512

typedef struct {
    _Atomic(void*) task_id;          // Swift task pointer (atomic for lock-free access)
    _Atomic(uint8_t*) coverage_map;  // Coverage bitmap for this task (atomic)
} TaskCoverageEntry;

// Registry of per-task coverage maps (lock-free)
static TaskCoverageEntry g_task_registry[MAX_TASK_ENTRIES];
static _Atomic(size_t) g_task_registry_count = 0;

// Thread-local fallback for non-async contexts
static _Thread_local uint8_t *tls_coverage_map = NULL;
static _Thread_local size_t tls_coverage_map_size = 0;

// MARK: - Per-Task Measurement Context Registry
// Measurement contexts are now tracked per-task to avoid TLS interference
// when multiple Swift tasks run on the same thread.

typedef struct {
    void* task_id;              // Swift task pointer (or pseudo-task for sync code)
    void* measurement_context;  // The measurement context ID
} TaskMeasurementEntry;

#define MAX_TASK_MEASUREMENT_ENTRIES 512

static TaskMeasurementEntry g_task_measurement_registry[MAX_TASK_MEASUREMENT_ENTRIES];
static size_t g_task_measurement_count = 0;
static pthread_mutex_t g_task_measurement_lock = PTHREAD_MUTEX_INITIALIZER;

// Thread-local pseudo-task ID for synchronous code outside async contexts
static _Thread_local void* tls_sync_pseudo_task = NULL;

// Thread-local cache for coverage map lookup.
// Only used for measurement contexts (not Swift tasks) because we can
// invalidate the cache when the measurement ends.
// Swift task pointers can be reused after a task completes, so caching
// those would be unsafe.
static _Thread_local void* tls_cached_measurement_context = NULL;
static _Thread_local uint8_t* tls_cached_coverage_map = NULL;

// Get or create a pseudo-task ID for synchronous code
static void* get_sync_pseudo_task(void) {
    if (tls_sync_pseudo_task == NULL) {
        // Use a unique heap address as pseudo-task ID
        tls_sync_pseudo_task = malloc(1);
    }
    return tls_sync_pseudo_task;
}

// Get the current task (Swift task or sync pseudo-task)
static void* get_current_task_for_measurement(void) {
    if (swift_task_getCurrent != NULL) {
        void* task = swift_task_getCurrent();
        if (task != NULL) {
            return task;
        }
    }
    return get_sync_pseudo_task();
}

// Get measurement context for a task
static void* get_measurement_context_for_task(void* task_id) {
    if (task_id == NULL) return NULL;

    pthread_mutex_lock(&g_task_measurement_lock);
    for (size_t i = 0; i < g_task_measurement_count; i++) {
        if (g_task_measurement_registry[i].task_id == task_id) {
            void* ctx = g_task_measurement_registry[i].measurement_context;
            pthread_mutex_unlock(&g_task_measurement_lock);
            return ctx;
        }
    }
    pthread_mutex_unlock(&g_task_measurement_lock);
    return NULL;
}

// Set measurement context for a task
static void set_measurement_context_for_task(void* task_id, void* context) {
    if (task_id == NULL) return;

    pthread_mutex_lock(&g_task_measurement_lock);

    // Check if entry already exists
    for (size_t i = 0; i < g_task_measurement_count; i++) {
        if (g_task_measurement_registry[i].task_id == task_id) {
            g_task_measurement_registry[i].measurement_context = context;
            pthread_mutex_unlock(&g_task_measurement_lock);
            return;
        }
    }

    // Add new entry
    if (g_task_measurement_count < MAX_TASK_MEASUREMENT_ENTRIES) {
        g_task_measurement_registry[g_task_measurement_count].task_id = task_id;
        g_task_measurement_registry[g_task_measurement_count].measurement_context = context;
        g_task_measurement_count++;
    }

    pthread_mutex_unlock(&g_task_measurement_lock);
}

// Remove measurement context for a task
static void remove_measurement_context_for_task(void* task_id) {
    if (task_id == NULL) return;

    pthread_mutex_lock(&g_task_measurement_lock);

    for (size_t i = 0; i < g_task_measurement_count; i++) {
        if (g_task_measurement_registry[i].task_id == task_id) {
            // Swap-remove
            if (i < g_task_measurement_count - 1) {
                g_task_measurement_registry[i] = g_task_measurement_registry[g_task_measurement_count - 1];
            }
            g_task_measurement_count--;
            break;
        }
    }

    pthread_mutex_unlock(&g_task_measurement_lock);
}

// Find or create a coverage map for the given task (lock-free).
// Uses atomic operations to ensure thread safety without locks.
//
// Memory safety: Coverage maps are never freed during runtime to prevent
// use-after-free races. Maps are reused when slots are reclaimed, and all
// memory is freed on process exit. This bounds memory usage to
// MAX_TASK_ENTRIES * g_guard_count bytes (~50MB worst case).
static uint8_t* find_or_create_task_map(void* task_id) {
    if (task_id == NULL || g_guard_count == 0) return NULL;

    // Search all slots for existing entry
    for (size_t i = 0; i < MAX_TASK_ENTRIES; i++) {
        void* stored_task = atomic_load_explicit(&g_task_registry[i].task_id, memory_order_acquire);
        if (stored_task == task_id) {
            // Found existing entry, return its coverage map
            uint8_t* map = atomic_load_explicit(&g_task_registry[i].coverage_map, memory_order_acquire);
            if (map != NULL) {
                return map;
            }
            // Map not set yet (shouldn't happen), fall through to claim a slot
        }
    }

    // Not found, try to claim a free slot
    for (size_t i = 0; i < MAX_TASK_ENTRIES; i++) {
        void* expected = NULL;
        if (atomic_compare_exchange_strong_explicit(
                &g_task_registry[i].task_id,
                &expected,
                task_id,
                memory_order_acq_rel,
                memory_order_acquire)) {
            // Successfully claimed this slot
            // Check if there's an existing map we can reuse (from a previous task)
            uint8_t* existing_map = atomic_load_explicit(&g_task_registry[i].coverage_map, memory_order_acquire);
            if (existing_map != NULL) {
                // Reuse existing map - just clear it
                memset(existing_map, 0, g_guard_count);
                return existing_map;
            }

            // No existing map, allocate a new one
            uint8_t* new_map = (uint8_t*)calloc(g_guard_count, 1);
            if (new_map == NULL) {
                // Allocation failed, release the slot
                atomic_store_explicit(&g_task_registry[i].task_id, NULL, memory_order_release);
                return NULL;
            }
            atomic_store_explicit(&g_task_registry[i].coverage_map, new_map, memory_order_release);

            // Update hint counter
            size_t count = atomic_load_explicit(&g_task_registry_count, memory_order_relaxed);
            if (i >= count) {
                atomic_store_explicit(&g_task_registry_count, i + 1, memory_order_relaxed);
            }
            return new_map;
        }

        // CAS failed - check if another thread added our task_id
        if (expected == task_id) {
            // Another thread added an entry for our task, use their map
            uint8_t* map = atomic_load_explicit(&g_task_registry[i].coverage_map, memory_order_acquire);
            // Spin-wait briefly if map isn't set yet (another thread is setting it)
            int spin_count = 0;
            while (map == NULL && spin_count < 1000) {
                map = atomic_load_explicit(&g_task_registry[i].coverage_map, memory_order_acquire);
                spin_count++;
            }
            if (map != NULL) {
                return map;
            }
            // Spin limit reached, fall through to try another slot
        }
    }

    // No free slots available
    return NULL;
}

// Mark a task map entry as available for reuse (lock-free).
// The coverage map memory is NOT freed - it will be reused by the next task
// that claims this slot. This prevents use-after-free races.
static void cleanup_task_map(void* task_id) {
    if (task_id == NULL) return;

    for (size_t i = 0; i < MAX_TASK_ENTRIES; i++) {
        void* stored_task = atomic_load_explicit(&g_task_registry[i].task_id, memory_order_acquire);
        if (stored_task == task_id) {
            // Found the entry - atomically clear the task_id to mark slot as available
            // Note: We intentionally do NOT free or clear the coverage_map pointer.
            // The map will be reused by the next task that claims this slot.
            atomic_compare_exchange_strong_explicit(
                    &g_task_registry[i].task_id,
                    &stored_task,
                    NULL,
                    memory_order_acq_rel,
                    memory_order_acquire);
            // If CAS failed, another thread already cleaned up - that's fine
            return;
        }
    }
}

// MARK: - Measurement Context API
// These functions provide isolation for measurements.
// Measurement contexts are now tracked per-task to avoid TLS interference
// when multiple Swift tasks run on the same thread.

void* sancov_begin_measurement(void) {
    // Use a unique address as the context ID
    void* context = malloc(1);

    // Associate this measurement context with the current task
    void* task = get_current_task_for_measurement();
    set_measurement_context_for_task(task, context);

    return context;
}

void sancov_end_measurement(void* context) {
    // Remove the measurement context from the current task
    void* task = get_current_task_for_measurement();
    remove_measurement_context_for_task(task);

    // Invalidate cache if it was using this context
    if (tls_cached_measurement_context == context) {
        tls_cached_measurement_context = NULL;
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
// Priority: measurement context (per-task) > Swift async task > thread-local
//
// Measurement contexts are looked up per-task to avoid TLS interference when
// multiple Swift tasks run on the same thread.
//
// Uses thread-local caching ONLY for measurement contexts (not Swift tasks).
// Measurement contexts have explicit begin/end calls so we can safely
// invalidate the cache. Swift task pointers can be reused after completion,
// making caching unsafe without explicit lifecycle management.
static uint8_t* get_current_coverage_map(void) {
    // Get the current task (Swift task or sync pseudo-task)
    void* task = get_current_task_for_measurement();

    // Check for measurement context for this task (highest priority)
    void* measurement_ctx = get_measurement_context_for_task(task);
    if (measurement_ctx != NULL) {
        // Fast path: check cache for measurement context
        if (measurement_ctx == tls_cached_measurement_context && tls_cached_coverage_map != NULL) {
            return tls_cached_coverage_map;
        }
        // Slow path: lookup or create, then cache
        uint8_t* map = find_or_create_task_map(measurement_ctx);
        if (map != NULL) {
            tls_cached_measurement_context = measurement_ctx;
            tls_cached_coverage_map = map;
            return map;
        }
    }

    // No measurement context - use the task's map directly
    if (task != NULL) {
        uint8_t* map = find_or_create_task_map(task);
        if (map != NULL) {
            return map;
        }
    }

    // Fallback to thread-local storage when registry is full
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
