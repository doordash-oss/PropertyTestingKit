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
static void* ck_malloc_wrapper(size_t size) { return malloc(size); }
static void ck_free_wrapper(void* ptr, size_t size, bool defer) {
    (void)size; (void)defer;
    free(ptr);
}

static struct ck_malloc ck_allocator = {
    .malloc = ck_malloc_wrapper,
    .free = ck_free_wrapper
};

// MARK: - Striped Locks for Reduced Contention
//
// Instead of a single global mutex, we use N striped locks.
// The hash value determines which stripe to lock, allowing concurrent
// writes to different keys as long as they hash to different stripes.

#define STRIPE_COUNT 64
#define STRIPE_MASK (STRIPE_COUNT - 1)

// Get stripe index from hash value
static inline size_t get_stripe_index(uint64_t hash) {
    return (size_t)(hash & STRIPE_MASK);
}

// Coverage registry: task_id -> coverage_map
static ck_ht_t g_coverage_ht;
static bool g_coverage_ht_initialized = false;
static pthread_mutex_t g_coverage_init_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_coverage_stripe_mutexes[STRIPE_COUNT];
static pthread_mutex_t g_coverage_resize_mutex = PTHREAD_MUTEX_INITIALIZER;  // Global lock for resize operations
static bool g_coverage_stripes_initialized = false;

// Thread-local fallback for non-async contexts
static _Thread_local uint8_t *tls_coverage_map = NULL;
static _Thread_local size_t tls_coverage_map_size = 0;

// Measurement registry: task_id -> measurement_context
static ck_ht_t g_measurement_ht;
static bool g_measurement_ht_initialized = false;
static pthread_mutex_t g_measurement_init_mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t g_measurement_stripe_mutexes[STRIPE_COUNT];
static pthread_mutex_t g_measurement_resize_mutex = PTHREAD_MUTEX_INITIALIZER;  // Global lock for resize operations
static bool g_measurement_stripes_initialized = false;

// Thread-local pseudo-task ID for synchronous code outside async contexts
static _Thread_local void* tls_sync_pseudo_task = NULL;

// Thread-local cache for coverage map lookup (avoids rwlock acquisition in hot path)
// The cache is invalidated when task changes or measurement context ends
static _Thread_local void* tls_cached_task = NULL;
static _Thread_local uint8_t* tls_cached_task_map = NULL;
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

// MARK: - ck_ht-based Lock-Free Hash Table Operations
//
// All operations are lock-free using ck_ht's SPMC (single-producer-multi-consumer) API.
// Initialization uses a mutex for one-time setup only.

// Initial capacity for hash tables - large enough to avoid resizes
// ck_ht resizes at 50% load, so this handles up to ~2000 concurrent measurements
#define CK_HT_INITIAL_CAPACITY 4096

// Debug logging control - set to 1 to enable
#define CK_HT_DEBUG_LOGGING 1

// Lazy initialization of hash tables and stripe mutexes
static void ensure_measurement_ht(void) {
    if (!g_measurement_ht_initialized) {
        pthread_mutex_lock(&g_measurement_init_mutex);
        if (!g_measurement_ht_initialized) {
            // Initialize stripe mutexes
            if (!g_measurement_stripes_initialized) {
                for (size_t i = 0; i < STRIPE_COUNT; i++) {
                    pthread_mutex_init(&g_measurement_stripe_mutexes[i], NULL);
                }
                g_measurement_stripes_initialized = true;
            }
            // Start with large capacity to avoid resizes during typical usage
            // ck_ht resizes at 50% load, so this handles up to ~2000 concurrent measurements
            ck_ht_init(&g_measurement_ht, CK_HT_MODE_DIRECT, NULL, &ck_allocator, CK_HT_INITIAL_CAPACITY, 0);
            g_measurement_ht_initialized = true;
#if CK_HT_DEBUG_LOGGING
            fprintf(stderr, "[CK_HT DEBUG] INIT measurement_ht: capacity=%d (requested)\n",
                    CK_HT_INITIAL_CAPACITY);
#endif
        }
        pthread_mutex_unlock(&g_measurement_init_mutex);
    }
}

static void ensure_coverage_ht(void) {
    if (!g_coverage_ht_initialized) {
        pthread_mutex_lock(&g_coverage_init_mutex);
        if (!g_coverage_ht_initialized) {
            // Initialize stripe mutexes
            if (!g_coverage_stripes_initialized) {
                for (size_t i = 0; i < STRIPE_COUNT; i++) {
                    pthread_mutex_init(&g_coverage_stripe_mutexes[i], NULL);
                }
                g_coverage_stripes_initialized = true;
            }
            // Start with large capacity to avoid resizes during typical usage
            ck_ht_init(&g_coverage_ht, CK_HT_MODE_DIRECT, NULL, &ck_allocator, CK_HT_INITIAL_CAPACITY, 0);
            g_coverage_ht_initialized = true;
#if CK_HT_DEBUG_LOGGING
            fprintf(stderr, "[CK_HT DEBUG] INIT coverage_ht: capacity=%d (requested)\n",
                    CK_HT_INITIAL_CAPACITY);
#endif
        }
        pthread_mutex_unlock(&g_coverage_init_mutex);
    }
}

// MARK: - Measurement Context Registry Operations (lock-free with ck_ht)

// Get measurement context for a task (lock-free lookup)
static void* get_measurement_context_for_task(void* task_id) {
    if (task_id == NULL || !g_measurement_ht_initialized) return NULL;

    ck_ht_entry_t entry;
    ck_ht_hash_t h;

    ck_ht_hash_direct(&h, &g_measurement_ht, (uintptr_t)task_id);
    ck_ht_entry_key_set_direct(&entry, (uintptr_t)task_id);

    if (ck_ht_get_spmc(&g_measurement_ht, h, &entry)) {
        return (void*)ck_ht_entry_value_direct(&entry);
    }
    return NULL;
}

// Debug counter for tracking registry exhaustion (kept for API compatibility)
static _Atomic(size_t) g_measurement_registry_failures = 0;

size_t sancov_get_measurement_registry_failures(void) {
    return atomic_load(&g_measurement_registry_failures);
}

// Check if hash table is near resize threshold (40% of capacity)
// ck_ht resizes at 50%, so 40% gives us headroom
static inline bool ck_ht_near_resize(ck_ht_t *ht) {
    // Use public API to get entry count
    // Capacity is known to be CK_HT_INITIAL_CAPACITY (we never resize)
    size_t entries = ck_ht_count(ht);
    return (entries * 5) > (CK_HT_INITIAL_CAPACITY * 2);  // > 40%
}

#if CK_HT_DEBUG_LOGGING
// Track peak entries for each hash table
static _Atomic size_t g_measurement_peak_entries = 0;
static _Atomic size_t g_coverage_peak_entries = 0;

static inline void log_ht_stats(const char* operation, ck_ht_t *ht, const char* ht_name) {
    size_t entries = ck_ht_count(ht);
    // We know capacity is CK_HT_INITIAL_CAPACITY (4096)
    size_t capacity = CK_HT_INITIAL_CAPACITY;
    double load = (double)entries / (double)capacity * 100.0;

    // Track peak entries
    _Atomic size_t *peak = (ht == &g_measurement_ht) ? &g_measurement_peak_entries : &g_coverage_peak_entries;
    size_t current_peak = atomic_load(peak);
    while (entries > current_peak) {
        if (atomic_compare_exchange_weak(peak, &current_peak, entries)) {
            // New peak! Always log this
            fprintf(stderr, "[CK_HT DEBUG] NEW PEAK %s: entries=%zu capacity=%zu load=%.1f%%\n",
                    ht_name, entries, capacity, load);
            break;
        }
    }

    // Only log periodically to avoid flooding
    static _Atomic size_t log_counter = 0;
    size_t count = atomic_fetch_add(&log_counter, 1);

    // Log every 1000 operations or if near resize threshold
    bool near_resize = (entries * 2) > capacity;  // >50% = resize territory
    if (count % 1000 == 0 || near_resize) {
        fprintf(stderr, "[CK_HT DEBUG] %s %s: entries=%zu peak=%zu capacity=%zu load=%.1f%% %s\n",
                operation, ht_name, entries, atomic_load(peak), capacity, load,
                near_resize ? "⚠️ NEAR RESIZE!" : "");
    }
}
#else
#define log_ht_stats(op, ht, name) ((void)0)
#endif

// Set measurement context for a task
// Uses striped locks - atomic counters in ck_ht now prevent n_entries drift
static bool set_measurement_context_for_task(void* task_id, void* context) {
    if (task_id == NULL) return false;

    ensure_measurement_ht();

    ck_ht_entry_t entry;
    ck_ht_hash_t h;

    ck_ht_hash_direct(&h, &g_measurement_ht, (uintptr_t)task_id);
    ck_ht_entry_set_direct(&entry, h, (uintptr_t)task_id, (uintptr_t)context);

    // Log BEFORE operation
    log_ht_stats("SET_BEFORE", &g_measurement_ht, "measurement");

    // Use striped lock for reduced contention
    size_t stripe = get_stripe_index(h.value);
    pthread_mutex_lock(&g_measurement_stripe_mutexes[stripe]);
    bool success = ck_ht_set_spmc(&g_measurement_ht, h, &entry);
    // Log AFTER operation
    log_ht_stats("SET_AFTER", &g_measurement_ht, "measurement");
    pthread_mutex_unlock(&g_measurement_stripe_mutexes[stripe]);

    if (!success) {
        atomic_fetch_add(&g_measurement_registry_failures, 1);
        return false;
    }
    return true;
}

// Remove measurement context for a task
// Uses striped locks - atomic counters in ck_ht now prevent n_entries drift
static void remove_measurement_context_for_task(void* task_id) {
    if (task_id == NULL || !g_measurement_ht_initialized) return;

    ck_ht_entry_t entry;
    ck_ht_hash_t h;

    ck_ht_hash_direct(&h, &g_measurement_ht, (uintptr_t)task_id);
    ck_ht_entry_key_set_direct(&entry, (uintptr_t)task_id);

    size_t stripe = get_stripe_index(h.value);
    pthread_mutex_lock(&g_measurement_stripe_mutexes[stripe]);
    ck_ht_remove_spmc(&g_measurement_ht, h, &entry);
    pthread_mutex_unlock(&g_measurement_stripe_mutexes[stripe]);
}

// MARK: - Coverage Map Registry Operations (lock-free with ck_ht)

// Find or create a coverage map for the given task
// Coverage maps are cached and reused to avoid repeated allocation
// Uses lock-free reads, striped locks for writes (large initial capacity avoids resizes)
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

    // Log BEFORE acquiring lock
    log_ht_stats("COVERAGE_INSERT_BEFORE", &g_coverage_ht, "coverage");

    // Use striped lock for reduced contention
    size_t stripe = get_stripe_index(h.value);
    pthread_mutex_lock(&g_coverage_stripe_mutexes[stripe]);

    // Double-check after acquiring lock (another thread may have inserted)
    ck_ht_entry_key_set_direct(&entry, (uintptr_t)task_id);
    if (ck_ht_get_spmc(&g_coverage_ht, h, &entry)) {
        pthread_mutex_unlock(&g_coverage_stripe_mutexes[stripe]);
        free(new_map);
        return (uint8_t*)ck_ht_entry_value_direct(&entry);
    }

    // Insert our new map
    ck_ht_entry_set_direct(&entry, h, (uintptr_t)task_id, (uintptr_t)new_map);
    bool success = ck_ht_set_spmc(&g_coverage_ht, h, &entry);

    // Log AFTER operation
    log_ht_stats("COVERAGE_INSERT_AFTER", &g_coverage_ht, "coverage");

    pthread_mutex_unlock(&g_coverage_stripe_mutexes[stripe]);

    if (!success) {
        free(new_map);
        return NULL;
    }

    return new_map;
}

// Remove a task's coverage map entry (striped lock)
static void cleanup_task_map(void* task_id) {
    if (task_id == NULL || !g_coverage_ht_initialized) return;

    ck_ht_entry_t entry;
    ck_ht_hash_t h;

    ck_ht_hash_direct(&h, &g_coverage_ht, (uintptr_t)task_id);
    ck_ht_entry_key_set_direct(&entry, (uintptr_t)task_id);

    size_t stripe = get_stripe_index(h.value);
    pthread_mutex_lock(&g_coverage_stripe_mutexes[stripe]);
    bool removed = ck_ht_remove_spmc(&g_coverage_ht, h, &entry);
    pthread_mutex_unlock(&g_coverage_stripe_mutexes[stripe]);

    if (removed) {
        // Entry was found and removed - free the coverage map
        uint8_t* map = (uint8_t*)ck_ht_entry_value_direct(&entry);
        if (map != NULL) {
            free(map);
        }
    }
}

// MARK: - Measurement Context API
// These functions provide isolation for measurements.
// Measurement contexts are now tracked per-task to avoid TLS interference
// when multiple Swift tasks run on the same thread.

// Measurement context structure - caches coverage map pointer for fast access
typedef struct {
    uint8_t* coverage_map;  // Direct pointer to coverage map (cached for speed)
} MeasurementContextData;

void* sancov_begin_measurement(void) {
    // Allocate the context structure
    MeasurementContextData* ctx = (MeasurementContextData*)malloc(sizeof(MeasurementContextData));
    if (ctx == NULL) return NULL;

    ctx->coverage_map = NULL;

    // Associate this measurement context with the current task
    // This is critical for coverage isolation - if it fails, we can't guarantee isolation
    void* task = get_current_task_for_measurement();
    if (!set_measurement_context_for_task(task, ctx)) {
        // Registration failed - clean up and return NULL
        free(ctx);
        return NULL;
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

void sancov_end_measurement(void* context) {
    if (context == NULL) return;

    MeasurementContextData* ctx = (MeasurementContextData*)context;

    // Remove the measurement context from the current task
    void* task = get_current_task_for_measurement();
    remove_measurement_context_for_task(task);

    // Invalidate ALL caches since measurement is ending
    // This ensures the next lookup will get the correct map
    if (tls_cached_measurement_context == context) {
        tls_cached_measurement_context = NULL;
        tls_cached_coverage_map = NULL;
    }
    // Also invalidate task cache since it may have pointed to measurement map
    tls_cached_task = NULL;
    tls_cached_task_map = NULL;

    // Clean up the task registry entry for this context
    cleanup_task_map(context);
    free(ctx);
}

// MARK: - Context-Aware API
// These functions operate directly on a measurement context, bypassing TLS lookup.
// This is critical for Swift concurrency where tasks can hop between threads.

void sancov_reset_counters_with_context(void* context) {
    if (context == NULL || g_guard_count == 0) return;

    MeasurementContextData* ctx = (MeasurementContextData*)context;

    // FAST PATH: Use cached coverage map directly
    if (ctx->coverage_map != NULL) {
        memset(ctx->coverage_map, 0, g_guard_count);
        return;
    }

    // SLOW PATH: Look up the map (should rarely happen)
    uint8_t* map = find_or_create_task_map(context);
    if (map != NULL) {
        ctx->coverage_map = map;
        memset(map, 0, g_guard_count);
    }
}

const uint8_t* sancov_get_counters_with_context(void* context) {
    if (context == NULL || g_guard_count == 0) return NULL;

    MeasurementContextData* ctx = (MeasurementContextData*)context;

    // FAST PATH: Use cached coverage map directly
    if (ctx->coverage_map != NULL) {
        return ctx->coverage_map;
    }

    // SLOW PATH: Look up the map
    uint8_t* map = find_or_create_task_map(context);
    if (map != NULL) {
        ctx->coverage_map = map;
    }
    return map;
}

size_t sancov_snapshot_covered_indices_with_context(void* context, uint32_t* indices, uint8_t* counts, size_t max_entries) {
    const uint8_t* counters = sancov_get_counters_with_context(context);
    size_t counter_count = sancov_get_counter_count();
    if (!counters || counter_count == 0) return 0;

#if USE_NEON_SIMD
    // SIMD-optimized version using ARM NEON
    if (indices == NULL) {
        size_t covered = 0;
        size_t i = 0;
        uint8x16_t zero = vdupq_n_u8(0);
        for (; i + 16 <= counter_count; i += 16) {
            uint8x16_t chunk = vld1q_u8(counters + i);
            uint8x16_t cmp = vcgtq_u8(chunk, zero);
            uint8x8_t sum8 = vadd_u8(vget_low_u8(cmp), vget_high_u8(cmp));
            uint64_t mask = vget_lane_u64(vreinterpret_u64_u8(sum8), 0);
            covered += __builtin_popcountll(mask) / 8;
        }
        for (; i < counter_count; i++) {
            if (counters[i] > 0) covered++;
        }
        return covered;
    }

    size_t filled = 0;
    size_t i = 0;
    uint8x16_t zero = vdupq_n_u8(0);
    for (; i + 16 <= counter_count && filled < max_entries; i += 16) {
        uint8x16_t chunk = vld1q_u8(counters + i);
        uint8x16_t cmp = vcgtq_u8(chunk, zero);
        uint64x2_t cmp64 = vreinterpretq_u64_u8(cmp);
        if (vgetq_lane_u64(cmp64, 0) == 0 && vgetq_lane_u64(cmp64, 1) == 0) {
            continue;
        }
        for (size_t j = 0; j < 16 && filled < max_entries; j++) {
            if (counters[i + j] > 0) {
                indices[filled] = (uint32_t)(i + j);
                if (counts) counts[filled] = counters[i + j];
                filled++;
            }
        }
    }
    for (; i < counter_count && filled < max_entries; i++) {
        if (counters[i] > 0) {
            indices[filled] = (uint32_t)i;
            if (counts) counts[filled] = counters[i];
            filled++;
        }
    }
    return filled;
#else
    // Scalar fallback
    if (indices == NULL) {
        size_t covered = 0;
        for (size_t i = 0; i < counter_count; i++) {
            if (counters[i] > 0) covered++;
        }
        return covered;
    }

    size_t filled = 0;
    for (size_t i = 0; i < counter_count && filled < max_entries; i++) {
        if (counters[i] > 0) {
            indices[filled] = (uint32_t)i;
            if (counts) counts[filled] = counters[i];
            filled++;
        }
    }
    return filled;
#endif
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
// PERFORMANCE CRITICAL: This function is called on EVERY basic block execution.
// We use aggressive thread-local caching to avoid O(512) registry scans.
//
// Cache strategy:
// 1. Check if task pointer matches cached task → return cached map (O(1))
// 2. If task changed, check for measurement context
// 3. Lookup/create map and update cache
//
// The cache is safe because:
// - Within consecutive trace_pc_guard calls on the same thread, the task is stable
// - When tasks hop threads, the new thread has a different cache
// - Measurement end explicitly invalidates the cache
static uint8_t* get_current_coverage_map(void) {
    // Get the current task (Swift task or sync pseudo-task)
    void* task = get_current_task_for_measurement();

    // FAST PATH: Check if we have a cached map for this exact task
    // This avoids the O(512) scans in the common case where the task hasn't changed
    if (task == tls_cached_task && tls_cached_task_map != NULL) {
        return tls_cached_task_map;
    }

    // Task changed - need to do full lookup
    // First check for measurement context for this task (highest priority)
    void* measurement_ctx = get_measurement_context_for_task(task);
    if (measurement_ctx != NULL) {
        // Check measurement context cache
        if (measurement_ctx == tls_cached_measurement_context && tls_cached_coverage_map != NULL) {
            // Update task cache to point to measurement map
            tls_cached_task = task;
            tls_cached_task_map = tls_cached_coverage_map;
            return tls_cached_coverage_map;
        }
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
            if (counters[i] > 0) covered++;
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
            if (counters[i + j] > 0) {
                indices[filled] = (uint32_t)(i + j);
                if (counts) counts[filled] = counters[i + j];
                filled++;
            }
        }
    }

    // Handle remaining bytes
    for (; i < counter_count && filled < max_entries; i++) {
        if (counters[i] > 0) {
            indices[filled] = (uint32_t)i;
            if (counts) counts[filled] = counters[i];
            filled++;
        }
    }
    return filled;

#else
    // Fallback: scalar implementation for non-ARM platforms
    if (indices == NULL) {
        size_t covered = 0;
        for (size_t i = 0; i < counter_count; i++) {
            if (counters[i] > 0) covered++;
        }
        return covered;
    }

    size_t filled = 0;
    for (size_t i = 0; i < counter_count && filled < max_entries; i++) {
        if (counters[i] > 0) {
            indices[filled] = (uint32_t)i;
            if (counts) counts[filled] = counters[i];
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

// Counter for dladdr calls (for profiling)
static _Atomic size_t g_dladdr_call_count = 0;

size_t sancov_get_dladdr_call_count(void) {
    return atomic_load(&g_dladdr_call_count);
}

void sancov_reset_dladdr_call_count(void) {
    atomic_store(&g_dladdr_call_count, 0);
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

    // Use dladdr to get symbol info
    Dl_info info;
    atomic_fetch_add(&g_dladdr_call_count, 1);
    if (dladdr((void*)pc, &info)) {
        location->filename = info.dli_fname;
        location->function_name = info.dli_sname;
        location->function_start = (uintptr_t)info.dli_saddr;
    }

    return true;
}

size_t sancov_get_source_locations_batch(const size_t* edge_indices, SanCovSourceLocation* locations, size_t count) {
    if (!edge_indices || !locations || count == 0) return 0;

    size_t filled = 0;
    for (size_t i = 0; i < count; i++) {
        if (sancov_get_source_location(edge_indices[i], &locations[i])) {
            filled++;
        }
    }
    return filled;
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
