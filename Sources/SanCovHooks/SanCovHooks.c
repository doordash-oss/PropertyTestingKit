//
//  SanCovHooks.c
//  PropertyTestingKit
//
//  Implementation of LLVM SanitizerCoverage hooks for coverage-guided fuzzing.
//

#include "include/SanCovHooks.h"
#include <string.h>
#include <dlfcn.h>

// SIMD support for ARM64 NEON
#if defined(__aarch64__) || defined(__arm64__)
#include <arm_neon.h>
#define USE_NEON_SIMD 1
#endif

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
#include <stdio.h>
#include <stdatomic.h>

// Wrapper that aborts on allocation failure - keeps callsites clean
static void* xmalloc(size_t size) {
    void* ptr = malloc(size);
    if (ptr == NULL) {
        fprintf(stderr, "FATAL: malloc(%zu) failed\n", size);
        fflush(stderr);
        abort();
    }
    return ptr;
}

// Forward declare Swift runtime function
// Returns the current Swift Task pointer, or NULL if not in an async context
extern void* swift_task_getCurrent(void) __attribute__((weak_import));

// Global guard metadata (shared across all tasks/threads, read-only after init)
static uint32_t *g_guards_start = NULL;
static uint32_t *g_guards_end = NULL;
static size_t g_guard_count = 0;

// MARK: - Lock-Free Hash Tables using ConcurrencyKit ck_ht
//
// Design: Use ck_ht (BSD licensed, battle-tested) for truly lock-free operations.
// - ck_ht_get_spmc: lock-free lookup (single-producer-multi-consumer)
// - ck_ht_set_spmc: lock-free insert/replace
// - ck_ht_remove_spmc: lock-free delete
// - Automatic resizing with safe memory reclamation

#include "include/ck/ck_ht.h"
#include <pthread.h>

// Memory allocator for ck_ht
static void* ck_malloc_wrapper(size_t size) { return xmalloc(size); }
static void ck_free_wrapper(void* ptr, size_t size, bool defer) {
    (void)size; (void)defer;
    free(ptr);
}

static struct ck_malloc ck_allocator = {
    .malloc = ck_malloc_wrapper,
    .free = ck_free_wrapper
};

// MARK: - Lock-Free Hash Table State
//
// ck_ht operations are lock-free for reads. For writes, we rely on ck_ht's
// internal handling. Initialization uses pthread_once for thread-safety.

// Coverage registry: task_id -> coverage_map
static ck_ht_t g_coverage_ht;
static pthread_once_t g_coverage_ht_once = PTHREAD_ONCE_INIT;

// Thread-local fallback for non-async contexts
static _Thread_local uint8_t *tls_coverage_map = NULL;

// Measurement registry: task_id -> measurement_context
static ck_ht_t g_measurement_ht;
static pthread_once_t g_measurement_ht_once = PTHREAD_ONCE_INIT;

// Thread-local pseudo-task ID for synchronous code outside async contexts
static _Thread_local void* tls_sync_pseudo_task = NULL;

// Global generation counter - incremented when any measurement context ends.
// Used to invalidate stale TLS caches across all threads.
static _Atomic uint64_t g_measurement_generation = 0;

// Thread-local cache for coverage map lookup (avoids rwlock acquisition in hot path)
// The cache is invalidated when task changes or measurement context ends
static _Thread_local void* tls_cached_task = NULL;
static _Thread_local uint8_t* tls_cached_task_map = NULL;
static _Thread_local SanCovMeasurementContext* tls_cached_measurement_context = NULL;
static _Thread_local uint8_t* tls_cached_coverage_map = NULL;
static _Thread_local uint64_t tls_cached_generation = 0;

// Get or create a pseudo-task ID for synchronous code
static void* get_sync_pseudo_task(void) {
    if (tls_sync_pseudo_task == NULL) {
        // Use a unique heap address as pseudo-task ID
        tls_sync_pseudo_task = xmalloc(1);
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

// MARK: - ck_ht-based Lock-Free Hash Table Operations
//
// All operations are lock-free using ck_ht's SPMC (single-producer-multi-consumer) API.
// Initialization uses a mutex for one-time setup only.

// Initial capacity for hash tables
// ck_ht resizes at 50% load. Resize is now safe with the resize_in_progress flag.
// Start small and grow as needed.
#define CK_HT_INITIAL_CAPACITY 256

static void init_measurement_ht(void) {
    ck_ht_init(&g_measurement_ht, CK_HT_MODE_DIRECT, NULL, &ck_allocator, CK_HT_INITIAL_CAPACITY, 0);
}

static void init_coverage_ht(void) {
    ck_ht_init(&g_coverage_ht, CK_HT_MODE_DIRECT, NULL, &ck_allocator, CK_HT_INITIAL_CAPACITY, 0);
}

// Lazy initialization using pthread_once (lock-free after first call)
static inline void ensure_measurement_ht(void) {
    pthread_once(&g_measurement_ht_once, init_measurement_ht);
}

static inline void ensure_coverage_ht(void) {
    pthread_once(&g_coverage_ht_once, init_coverage_ht);
}

// MARK: - Measurement Context Registry Operations (lock-free with ck_ht)

// Get measurement context for a task (lock-free lookup)
static void* get_measurement_context_for_task(void* task_id) {
    ensure_measurement_ht();

    ck_ht_entry_t entry;
    ck_ht_hash_t h;

    ck_ht_hash_direct(&h, &g_measurement_ht, (uintptr_t)task_id);
    ck_ht_entry_key_set_direct(&entry, (uintptr_t)task_id);

    if (ck_ht_get_spmc(&g_measurement_ht, h, &entry)) {
        return (void*)ck_ht_entry_value_direct(&entry);
    }
    return NULL;
}

// Set measurement context for a task (lock-free write)
static bool set_measurement_context_for_task(void* task_id, void* context) {
    ensure_measurement_ht();

    ck_ht_entry_t entry;
    ck_ht_hash_t h;

    ck_ht_hash_direct(&h, &g_measurement_ht, (uintptr_t)task_id);
    ck_ht_entry_set_direct(&entry, h, (uintptr_t)task_id, (uintptr_t)context);

    return ck_ht_set_spmc(&g_measurement_ht, h, &entry);
}

// Remove measurement context for a task (lock-free write)
static void remove_measurement_context_for_task(void* task_id) {
    ensure_measurement_ht();

    ck_ht_entry_t entry;
    ck_ht_hash_t h;

    ck_ht_hash_direct(&h, &g_measurement_ht, (uintptr_t)task_id);
    ck_ht_entry_key_set_direct(&entry, (uintptr_t)task_id);

    ck_ht_remove_spmc(&g_measurement_ht, h, &entry);
}

// MARK: - Coverage Map Registry Operations (lock-free with ck_ht)

// Find or create a coverage map for the given task
// Lock-free: uses ck_ht_put_spmc which only inserts if key doesn't exist
static uint8_t* find_or_create_task_map(void* task_id) {
    if (task_id == NULL || g_guard_count == 0) return NULL;

    ensure_coverage_ht();

    ck_ht_entry_t entry;
    ck_ht_hash_t h;

    // Lock-free lookup first (fast path for existing entries)
    ck_ht_hash_direct(&h, &g_coverage_ht, (uintptr_t)task_id);
    ck_ht_entry_key_set_direct(&entry, (uintptr_t)task_id);

    if (ck_ht_get_spmc(&g_coverage_ht, h, &entry)) {
        return (uint8_t*)ck_ht_entry_value_direct(&entry);
    }

    // Need to insert - allocate new coverage map
    uint8_t* new_map = (uint8_t*)calloc(g_guard_count, 1);
    if (new_map == NULL) {
        return NULL;
    }

    // Try to insert using put (fails if key already exists)
    ck_ht_entry_set_direct(&entry, h, (uintptr_t)task_id, (uintptr_t)new_map);
    bool inserted = ck_ht_put_spmc(&g_coverage_ht, h, &entry);

    if (!inserted) {
        // Another thread beat us - free our map and return existing one
        free(new_map);
        ck_ht_entry_key_set_direct(&entry, (uintptr_t)task_id);
        if (ck_ht_get_spmc(&g_coverage_ht, h, &entry)) {
            return (uint8_t*)ck_ht_entry_value_direct(&entry);
        }
        return NULL;  // Shouldn't happen, but handle gracefully
    }

    return new_map;
}

// Remove a task's coverage map entry (lock-free write)
static void cleanup_task_map(void* task_id) {
    ensure_coverage_ht();

    ck_ht_entry_t entry;
    ck_ht_hash_t h;

    ck_ht_hash_direct(&h, &g_coverage_ht, (uintptr_t)task_id);
    ck_ht_entry_key_set_direct(&entry, (uintptr_t)task_id);

    bool removed = ck_ht_remove_spmc(&g_coverage_ht, h, &entry);

    if (removed) {
        // Entry was found and removed - free the coverage map
        uint8_t* map = (uint8_t*)ck_ht_entry_value_direct(&entry);
        if (map != NULL) {
            free(map);
        }
    }
}

// MARK: - Measurement Context API

SanCovMeasurementContext* sancov_begin_measurement(void) {
    SanCovMeasurementContext* ctx = (SanCovMeasurementContext*)xmalloc(sizeof(SanCovMeasurementContext));
    ctx->coverage_map = NULL;
    ctx->covered_count = 0;

    // Associate this measurement context with the current task
    void* task = get_current_task_for_measurement();
    if (!set_measurement_context_for_task(task, ctx)) {
        fprintf(stderr, "FATAL: failed to register measurement context for task %p\n", task);
        abort();
    }

    // Pre-warm the cache by creating the coverage map now
    if (g_guard_count > 0) {
        uint8_t* map = find_or_create_task_map(ctx);
        if (map != NULL) {
            ctx->coverage_map = map;

            // Populate TLS caches for the current thread (may help if no hop occurs)
            tls_cached_measurement_context = ctx;
            tls_cached_coverage_map = map;
            tls_cached_task = task;
            tls_cached_task_map = map;
        }
    }

    return ctx;
}

/// Cleanup caches, etc
void sancov_end_measurement(SanCovMeasurementContext* ctx) {
    if (ctx == NULL) return;

    // Remove the measurement context from the current task
    void* task = get_current_task_for_measurement();
    remove_measurement_context_for_task(task);

    // Invalidate ALL caches since measurement is ending
    if (tls_cached_measurement_context == ctx) {
        tls_cached_measurement_context = NULL;
        tls_cached_coverage_map = NULL;
    }
    tls_cached_task = NULL;
    tls_cached_task_map = NULL;

    cleanup_task_map(ctx);
    free(ctx);
}

static const uint8_t* get_counters_with_context(SanCovMeasurementContext* ctx) {
    if (ctx == NULL || g_guard_count == 0) return NULL;

    if (ctx->coverage_map != NULL) {
        return ctx->coverage_map;
    }

    uint8_t* map = find_or_create_task_map(ctx);
    if (map != NULL) {
        ctx->coverage_map = map;
    }
    return map;
}

// Get covered count for a measurement context (O(1)).
size_t sancov_get_covered_count_with_context(SanCovMeasurementContext* ctx) {
    if (!ctx) return 0;
    return ctx->covered_count;
}

// Allocate and fill an array of covered edge indices.
//
// Scans the coverage map and returns indices of edges that were hit (counter != 0).
// The caller is responsible for freeing the returned array.
// Use sancov_get_covered_count_with_context() to get the array size.
//
// Returns:
//   Newly allocated array of covered indices, or NULL if none covered.
//   Caller must free() the returned pointer.
//
// The SIMD path processes 16 counters at a time, skipping zero chunks entirely.
uint32_t* sancov_snapshot_covered_indices_with_context(SanCovMeasurementContext* ctx) {
    if (!ctx) return NULL;

    size_t count = ctx->covered_count;
    if (count == 0) return NULL;

    const uint8_t* counters = get_counters_with_context(ctx);
    size_t counter_count = sancov_get_counter_count();
    if (!counters || counter_count == 0) return NULL;

    uint32_t* indices = (uint32_t*)xmalloc(count * sizeof(uint32_t));

#if USE_NEON_SIMD

    // Fill mode: extract indices of non-zero counters
    size_t filled = 0;
    size_t i = 0;
    uint8x16_t zero = vdupq_n_u8(0);

    for (; i + 16 <= counter_count && filled < count; i += 16) {
        uint8x16_t chunk = vld1q_u8(counters + i);
        uint8x16_t cmp = vcgtq_u8(chunk, zero);
        uint64x2_t cmp64 = vreinterpretq_u64_u8(cmp);

        // Skip entirely zero chunks (common case - coverage is sparse)
        if (vgetq_lane_u64(cmp64, 0) == 0 && vgetq_lane_u64(cmp64, 1) == 0) {
            continue;
        }

        // Extract individual non-zero indices from this chunk
        for (size_t j = 0; j < 16 && filled < count; j++) {
            if (counters[i + j] != 0) {
                indices[filled] = (uint32_t)(i + j);
                filled++;
            }
        }
    }

    // Handle remaining bytes
    for (; i < counter_count && filled < count; i++) {
        if (counters[i] != 0) {
            indices[filled] = (uint32_t)i;
            filled++;
        }
    }

#else
    // Scalar fallback for non-ARM platforms
    for (size_t i = 0, filled = 0; i < counter_count && filled < count; i++) {
        if (counters[i] != 0) {
            indices[filled] = (uint32_t)i;
            filled++;
        }
    }
#endif

    return indices;
}

// Ensure thread-local fallback map is allocated
static void ensure_tls_coverage_map(void) {
    if (tls_coverage_map == NULL && g_guard_count > 0) {
        tls_coverage_map = (uint8_t*)calloc(g_guard_count, 1);
    }
}

// Get the coverage map for the current execution context
// Priority: measurement context (per-task) > Swift async task > thread-local
//
// PERFORMANCE CRITICAL: This function is called on EVERY basic block execution.
// We use aggressive thread-local caching to avoid O(512) registry scans.
//
// Cache strategy:
// 1. Check if task pointer matches cached task → return cached map (O(1))
// 2. If task changed, check for measurement context
// 3. Lookup/create map and update cache
//
// WARNING: The TLS cache can become stale in the worker pool model where the same
// task runs multiple measurement iterations. When a task hops threads between
// iterations, threads it previously visited retain stale cache entries pointing
// to freed coverage maps.
//
// Define SANCOV_DISABLE_TLS_CACHE=1 to disable the fast path for debugging.
#ifndef SANCOV_DISABLE_TLS_CACHE
#define SANCOV_DISABLE_TLS_CACHE 0
#endif

static uint8_t* get_current_coverage_map(void) {
    // Get the current task (Swift task or sync pseudo-task)
    void* task = get_current_task_for_measurement();

#if !SANCOV_DISABLE_TLS_CACHE
    // FAST PATH: Check if we have a cached map for this exact task
    // This avoids the O(512) scans in the common case where the task hasn't changed
    if (task == tls_cached_task && tls_cached_task_map != NULL) {
        return tls_cached_task_map;
    }
#endif

    // Task changed - need to do full lookup
    // First check for measurement context for this task (highest priority)
    SanCovMeasurementContext* measurement_ctx = (SanCovMeasurementContext*)get_measurement_context_for_task(task);
    if (measurement_ctx != NULL) {
#if !SANCOV_DISABLE_TLS_CACHE
        // Check measurement context cache
        if (measurement_ctx == tls_cached_measurement_context && tls_cached_coverage_map != NULL) {
            // Update task cache to point to measurement map
            tls_cached_task = task;
            tls_cached_task_map = tls_cached_coverage_map;
            return tls_cached_coverage_map;
        }
#endif
        // Slow path: lookup or create, then cache
        uint8_t* map = find_or_create_task_map(measurement_ctx);
        if (map != NULL) {
            tls_cached_measurement_context = measurement_ctx;
            tls_cached_coverage_map = map;
            tls_cached_task = task;
            tls_cached_task_map = map;
            return map;
        }
    }

    // No measurement context - use thread-local storage directly
    // We don't create task-keyed entries in the hash table because they would
    // never be cleaned up (we don't have a hook for task completion).
    // TLS is fine here since coverage outside of measurements isn't isolated anyway.
    ensure_tls_coverage_map();
    tls_cached_task = task;
    tls_cached_task_map = tls_coverage_map;
    return tls_coverage_map;
}

// PC guard hooks - used by Swift's -sanitize-coverage=edge
void __sanitizer_cov_trace_pc_guard_init(uint32_t *start, uint32_t *stop) {
    // Skip empty sections
    if (start == stop) return;

    if (g_guards_start == NULL) {
        // First initialization
        g_guards_start = start;
        g_guards_end = stop;
        g_guard_count = (size_t)(stop - start);

        // Initialize guards to their index values so we know which edge was hit
        for (uint32_t *p = start; p < stop; p++) {
            *p = (uint32_t)(p - start);
        }
    } else if (start != g_guards_start || stop != g_guards_end) {
        // Multiple modules with separate guard sections detected.
        // This is not supported - we can only track one contiguous guard range.
        // The linker should merge all __sancov_guards sections into one.
        fprintf(stderr,
            "FATAL: __sanitizer_cov_trace_pc_guard_init called with multiple guard sections.\n"
            "  First section: %p - %p (%zu guards)\n"
            "  New section:   %p - %p (%zu guards)\n"
            "This indicates multiple compilation units with separate coverage sections.\n"
            "Ensure all code is linked into a single module or fix the linker configuration.\n",
            (void*)g_guards_start, (void*)g_guards_end, g_guard_count,
            (void*)start, (void*)stop, (size_t)(stop - start));
        abort();
    }
    // else: Same section passed again (harmless, can happen during re-initialization)
}

void __sanitizer_cov_trace_pc_guard(uint32_t *guard) {
    uint8_t* map = get_current_coverage_map();
    if (map && *guard < g_guard_count) {
        if (map[*guard] == 0) {
            map[*guard] = 1;
            if (tls_cached_measurement_context) {
                tls_cached_measurement_context->covered_count++;
            }
        }
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

// MARK: - Public API

bool sancov_counters_available(void) {
    return g_guard_count > 0;
}

size_t sancov_get_counter_count(void) {
    return g_guard_count;
}

size_t sancov_get_covered_count(void) {
    if (g_guard_count == 0) return 0;

    uint8_t* map = get_current_coverage_map();
    if (!map) return 0;

    size_t count = 0;
    for (size_t i = 0; i < g_guard_count; i++) {
        if (map[i]) count++;
    }
    return count;
}

const uint8_t* sancov_get_counters(void) {
    return get_current_coverage_map();
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

size_t sancov_snapshot_covered_indices(uint32_t* indices, size_t max_entries) {
    const uint8_t* counters = sancov_get_counters();
    size_t counter_count = sancov_get_counter_count();
    if (!counters || counter_count == 0) return 0;

#if USE_NEON_SIMD
    // SIMD-optimized version using ARM NEON
    // Process 16 bytes at a time, checking for any non-zero values

    if (indices == NULL) {
        // Count-only mode: use SIMD to quickly count non-zero bytes
        size_t covered = 0;
        size_t i = 0;

        // Process 16 bytes at a time
        uint8x16_t zero = vdupq_n_u8(0);
        for (; i + 16 <= counter_count; i += 16) {
            uint8x16_t chunk = vld1q_u8(counters + i);
            uint8x16_t cmp = vcgtq_u8(chunk, zero);  // Compare: chunk > 0

            // Count non-zero bytes using horizontal add
            // First reduce to 8-byte counts
            uint8x8_t sum8 = vadd_u8(vget_low_u8(cmp), vget_high_u8(cmp));
            // Then sum pairs to get total (each non-zero becomes 0xFF = -1 in signed)
            // We negate to count: each 0xFF becomes 1
            uint64_t mask = vget_lane_u64(vreinterpret_u64_u8(sum8), 0);
            // Count set bytes (each 0xFF byte represents one covered edge)
            covered += __builtin_popcountll(mask) / 8;
        }

        // Handle remaining bytes
        for (; i < counter_count; i++) {
            if (counters[i] != 0) covered++;
        }
        return covered;
    }

    // Fill mode: use SIMD to find non-zero chunks, then extract indices
    size_t filled = 0;
    size_t i = 0;

    uint8x16_t zero = vdupq_n_u8(0);
    for (; i + 16 <= counter_count && filled < max_entries; i += 16) {
        uint8x16_t chunk = vld1q_u8(counters + i);
        uint8x16_t cmp = vcgtq_u8(chunk, zero);

        // Quick check: any non-zero in this 16-byte chunk?
        uint64x2_t cmp64 = vreinterpretq_u64_u8(cmp);
        if (vgetq_lane_u64(cmp64, 0) == 0 && vgetq_lane_u64(cmp64, 1) == 0) {
            continue;  // Skip entirely zero chunk
        }

        // Extract non-zero indices from this chunk
        for (size_t j = 0; j < 16 && filled < max_entries; j++) {
            if (counters[i + j] != 0) {
                indices[filled] = (uint32_t)(i + j);
                filled++;
            }
        }
    }

    // Handle remaining bytes
    for (; i < counter_count && filled < max_entries; i++) {
        if (counters[i] != 0) {
            indices[filled] = (uint32_t)i;
            filled++;
        }
    }
    return filled;

#else
    // Fallback: scalar implementation for non-ARM platforms
    if (indices == NULL) {
        size_t covered = 0;
        for (size_t i = 0; i < counter_count; i++) {
            if (counters[i] != 0) covered++;
        }
        return covered;
    }

    size_t filled = 0;
    for (size_t i = 0; i < counter_count && filled < max_entries; i++) {
        if (counters[i] != 0) {
            indices[filled] = (uint32_t)i;
            filled++;
        }
    }
    return filled;
#endif
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
    location->function_start = 0;

    Dl_info info;
    if (dladdr((void*)pc, &info)) {
        location->filename = info.dli_fname;
        location->function_name = info.dli_sname;
        location->function_start = (uintptr_t)info.dli_saddr;
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
        if (counters[i] != 0) {
            if (locations != NULL && covered_count < max_locations) {
                sancov_get_source_location(i, &locations[covered_count]);
            }
            covered_count++;
        }
    }

    return covered_count;
}
