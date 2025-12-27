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

// MARK: - Task-Keyed Coverage Registry (Lock-Free)

// Registry size: Increased from 512 to support more parallel test execution.
// Each concurrent measurement context (task with active beginMeasurement/endMeasurement)
// needs one slot. With parallel tests, each test can have many concurrent tasks.
// Example: 30 tests × 50 concurrent seeds = 1500 slots needed.
#define MAX_TASK_ENTRIES 2048

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

// MARK: - Per-Task Measurement Context Registry (Lock-Free)
// Measurement contexts are tracked per-task to avoid TLS interference
// when multiple Swift tasks run on the same thread.
// Uses atomics for lock-free reads in the hot path.

typedef struct {
    _Atomic(void*) task_id;              // Swift task pointer (atomic for lock-free access)
    _Atomic(void*) measurement_context;  // The measurement context ID (atomic)
} TaskMeasurementEntry;

// Registry size: Increased from 512 to support more parallel test execution.
// Must be at least as large as MAX_TASK_ENTRIES since each measurement context
// needs both a task→context mapping and a context→map mapping.
#define MAX_TASK_MEASUREMENT_ENTRIES 2048

static TaskMeasurementEntry g_task_measurement_registry[MAX_TASK_MEASUREMENT_ENTRIES];

// Thread-local pseudo-task ID for synchronous code outside async contexts
static _Thread_local void* tls_sync_pseudo_task = NULL;

// Thread-local cache for coverage map lookup.
// We cache the task pointer and its corresponding coverage map to avoid
// repeated O(512) linear scans in the hot path.
//
// Safety: Swift task pointers CAN be reused after a task completes.
// However, within a single thread's execution of trace_pc_guard callbacks,
// the task pointer will remain valid. The cache is only used for the
// duration of consecutive callbacks on the same thread, which is safe.
//
// The cache is invalidated when:
// 1. The task pointer changes (detected on each lookup)
// 2. A measurement context ends (explicit invalidation)
// 3. A task map is cleaned up (we don't track this - but the task pointer
//    would have changed anyway before the slot could be reused)
static _Thread_local void* tls_cached_task = NULL;
static _Thread_local uint8_t* tls_cached_task_map = NULL;
static _Thread_local void* tls_cached_measurement_context = NULL;
static _Thread_local uint8_t* tls_cached_coverage_map = NULL;

// Thread-local cache for measurement context registry slot.
// Caches the slot index for the current task to avoid O(512) scans
// in set/get_measurement_context_for_task.
static _Thread_local void* tls_cached_mctx_task = NULL;
static _Thread_local size_t tls_cached_mctx_slot = SIZE_MAX;

// Thread-local cache for task coverage registry slot.
// Caches the slot index to avoid O(512) scans in find_or_create_task_map.
// Unlike mctx cache, this caches by slot (not task) since measurement contexts
// change each iteration but we want to reuse the same slot.
static _Thread_local size_t tls_cached_task_registry_slot = SIZE_MAX;

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

// Get measurement context for a task (lock-free)
static void* get_measurement_context_for_task(void* task_id) {
    if (task_id == NULL) return NULL;

    // FAST PATH: Check cached slot for this task
    if (task_id == tls_cached_mctx_task && tls_cached_mctx_slot < MAX_TASK_MEASUREMENT_ENTRIES) {
        void* stored_task = atomic_load_explicit(&g_task_measurement_registry[tls_cached_mctx_slot].task_id, memory_order_acquire);
        if (stored_task == task_id) {
            return atomic_load_explicit(&g_task_measurement_registry[tls_cached_mctx_slot].measurement_context, memory_order_acquire);
        }
        // Slot was reused by another task, invalidate cache
        tls_cached_mctx_task = NULL;
        tls_cached_mctx_slot = SIZE_MAX;
    }

    // SLOW PATH: Lock-free scan of all slots
    for (size_t i = 0; i < MAX_TASK_MEASUREMENT_ENTRIES; i++) {
        void* stored_task = atomic_load_explicit(&g_task_measurement_registry[i].task_id, memory_order_acquire);
        if (stored_task == task_id) {
            // Cache this slot for future lookups
            tls_cached_mctx_task = task_id;
            tls_cached_mctx_slot = i;
            return atomic_load_explicit(&g_task_measurement_registry[i].measurement_context, memory_order_acquire);
        }
    }
    return NULL;
}

// Debug counter for tracking registry exhaustion
static _Atomic(size_t) g_measurement_registry_failures = 0;

// Get the count of measurement registry failures (for debugging)
size_t sancov_get_measurement_registry_failures(void) {
    return atomic_load(&g_measurement_registry_failures);
}

// Set measurement context for a task (lock-free using CAS)
// Returns true on success, false if registry is full
static bool set_measurement_context_for_task(void* task_id, void* context) {
    if (task_id == NULL) return false;

    // FAST PATH 1: Check if we have a cached slot for this exact task
    if (task_id == tls_cached_mctx_task && tls_cached_mctx_slot < MAX_TASK_MEASUREMENT_ENTRIES) {
        void* stored_task = atomic_load_explicit(&g_task_measurement_registry[tls_cached_mctx_slot].task_id, memory_order_acquire);
        if (stored_task == task_id) {
            // Update existing entry directly
            atomic_store_explicit(&g_task_measurement_registry[tls_cached_mctx_slot].measurement_context, context, memory_order_release);
            return true;
        }
        // Slot was cleared or reused, try to reclaim it
        void* expected = NULL;
        if (atomic_compare_exchange_strong_explicit(
                &g_task_measurement_registry[tls_cached_mctx_slot].task_id,
                &expected,
                task_id,
                memory_order_acq_rel,
                memory_order_acquire)) {
            // Successfully reclaimed the slot
            atomic_store_explicit(&g_task_measurement_registry[tls_cached_mctx_slot].measurement_context, context, memory_order_release);
            tls_cached_mctx_task = task_id;
            return true;
        }
        // Slot was taken by another task, invalidate cache
        tls_cached_mctx_task = NULL;
        tls_cached_mctx_slot = SIZE_MAX;
    }

    // SLOW PATH: Check if entry already exists
    for (size_t i = 0; i < MAX_TASK_MEASUREMENT_ENTRIES; i++) {
        void* stored_task = atomic_load_explicit(&g_task_measurement_registry[i].task_id, memory_order_acquire);
        if (stored_task == task_id) {
            // Update existing entry and cache the slot
            atomic_store_explicit(&g_task_measurement_registry[i].measurement_context, context, memory_order_release);
            tls_cached_mctx_task = task_id;
            tls_cached_mctx_slot = i;
            return true;
        }
    }

    // Not found, try to claim a free slot
    for (size_t i = 0; i < MAX_TASK_MEASUREMENT_ENTRIES; i++) {
        void* expected = NULL;
        if (atomic_compare_exchange_strong_explicit(
                &g_task_measurement_registry[i].task_id,
                &expected,
                task_id,
                memory_order_acq_rel,
                memory_order_acquire)) {
            // Successfully claimed this slot, cache it
            atomic_store_explicit(&g_task_measurement_registry[i].measurement_context, context, memory_order_release);
            tls_cached_mctx_task = task_id;
            tls_cached_mctx_slot = i;
            return true;
        }
        // If CAS failed because another thread added our task_id, update it
        if (expected == task_id) {
            atomic_store_explicit(&g_task_measurement_registry[i].measurement_context, context, memory_order_release);
            tls_cached_mctx_task = task_id;
            tls_cached_mctx_slot = i;
            return true;
        }
    }
    // No free slots - track the failure
    atomic_fetch_add(&g_measurement_registry_failures, 1);
    return false;
}

// Remove measurement context for a task (lock-free using CAS)
// Note: We intentionally DO NOT invalidate tls_cached_mctx_slot here.
// Keeping the slot cached allows set_measurement_context_for_task to
// reclaim the same slot on the next iteration without scanning.
static void remove_measurement_context_for_task(void* task_id) {
    if (task_id == NULL) return;

    // FAST PATH: Check cached slot first
    if (task_id == tls_cached_mctx_task && tls_cached_mctx_slot < MAX_TASK_MEASUREMENT_ENTRIES) {
        void* stored_task = atomic_load_explicit(&g_task_measurement_registry[tls_cached_mctx_slot].task_id, memory_order_acquire);
        if (stored_task == task_id) {
            // Clear the measurement context first, then the task_id
            atomic_store_explicit(&g_task_measurement_registry[tls_cached_mctx_slot].measurement_context, NULL, memory_order_release);
            atomic_compare_exchange_strong_explicit(
                &g_task_measurement_registry[tls_cached_mctx_slot].task_id,
                &stored_task,
                NULL,
                memory_order_acq_rel,
                memory_order_acquire);
            // Keep the slot cached for quick reclaim on next set
            return;
        }
    }

    // SLOW PATH: Scan all slots
    for (size_t i = 0; i < MAX_TASK_MEASUREMENT_ENTRIES; i++) {
        void* stored_task = atomic_load_explicit(&g_task_measurement_registry[i].task_id, memory_order_acquire);
        if (stored_task == task_id) {
            // Clear the measurement context first, then the task_id
            atomic_store_explicit(&g_task_measurement_registry[i].measurement_context, NULL, memory_order_release);
            // Use CAS to clear task_id (another thread might have already done it)
            atomic_compare_exchange_strong_explicit(
                &g_task_measurement_registry[i].task_id,
                &stored_task,
                NULL,
                memory_order_acq_rel,
                memory_order_acquire);
            // Cache this slot for quick reclaim
            tls_cached_mctx_task = task_id;
            tls_cached_mctx_slot = i;
            return;
        }
    }
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

    // FAST PATH: Try to reclaim the cached slot if it's free
    // This is the common case for sequential fuzzing iterations on the same thread
    if (tls_cached_task_registry_slot < MAX_TASK_ENTRIES) {
        void* expected = NULL;
        if (atomic_compare_exchange_strong_explicit(
                &g_task_registry[tls_cached_task_registry_slot].task_id,
                &expected,
                task_id,
                memory_order_acq_rel,
                memory_order_acquire)) {
            // Successfully reclaimed the cached slot
            uint8_t* existing_map = atomic_load_explicit(&g_task_registry[tls_cached_task_registry_slot].coverage_map, memory_order_acquire);
            if (existing_map != NULL) {
                // Reuse existing map - just clear it
                memset(existing_map, 0, g_guard_count);
                return existing_map;
            }
            // No existing map (shouldn't happen since we cache after first use)
            uint8_t* new_map = (uint8_t*)calloc(g_guard_count, 1);
            if (new_map == NULL) {
                atomic_store_explicit(&g_task_registry[tls_cached_task_registry_slot].task_id, NULL, memory_order_release);
                tls_cached_task_registry_slot = SIZE_MAX;
                return NULL;
            }
            atomic_store_explicit(&g_task_registry[tls_cached_task_registry_slot].coverage_map, new_map, memory_order_release);
            return new_map;
        }
        // Cached slot was taken by another thread, invalidate and continue to slow path
        tls_cached_task_registry_slot = SIZE_MAX;
    }

    // SLOW PATH: Search all slots for existing entry
    for (size_t i = 0; i < MAX_TASK_ENTRIES; i++) {
        void* stored_task = atomic_load_explicit(&g_task_registry[i].task_id, memory_order_acquire);
        if (stored_task == task_id) {
            // Found existing entry, cache slot and return its coverage map
            tls_cached_task_registry_slot = i;
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
            // Successfully claimed this slot, cache it
            tls_cached_task_registry_slot = i;

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
                tls_cached_task_registry_slot = SIZE_MAX;
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
            // Another thread added an entry for our task, cache and use their map
            tls_cached_task_registry_slot = i;
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
// Note: We keep tls_cached_task_registry_slot valid so the next find_or_create_task_map
// can reclaim the same slot without scanning.
static void cleanup_task_map(void* task_id) {
    if (task_id == NULL) return;

    // FAST PATH: Check cached slot first
    if (tls_cached_task_registry_slot < MAX_TASK_ENTRIES) {
        void* stored_task = atomic_load_explicit(&g_task_registry[tls_cached_task_registry_slot].task_id, memory_order_acquire);
        if (stored_task == task_id) {
            // Found the entry at cached slot - clear it but KEEP the slot cached for reclaim
            atomic_compare_exchange_strong_explicit(
                    &g_task_registry[tls_cached_task_registry_slot].task_id,
                    &stored_task,
                    NULL,
                    memory_order_acq_rel,
                    memory_order_acquire);
            return;
        }
    }

    // SLOW PATH: Scan all slots
    for (size_t i = 0; i < MAX_TASK_ENTRIES; i++) {
        void* stored_task = atomic_load_explicit(&g_task_registry[i].task_id, memory_order_acquire);
        if (stored_task == task_id) {
            // Found the entry - atomically clear the task_id to mark slot as available
            // Cache this slot for quick reclaim on next find_or_create_task_map
            tls_cached_task_registry_slot = i;
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

// Measurement context structure - stores slot index for O(1) lookup even after task hop
typedef struct {
    size_t slot_index;      // Index in g_task_registry (for O(1) map lookup)
    uint8_t* coverage_map;  // Direct pointer to coverage map (cached for speed)
} MeasurementContextData;

void* sancov_begin_measurement(void) {
    // Allocate the context structure
    MeasurementContextData* ctx = (MeasurementContextData*)malloc(sizeof(MeasurementContextData));
    if (ctx == NULL) return NULL;

    ctx->slot_index = SIZE_MAX;
    ctx->coverage_map = NULL;

    // Associate this measurement context with the current task
    // This is critical for coverage isolation - if it fails, we can't guarantee isolation
    void* task = get_current_task_for_measurement();
    if (!set_measurement_context_for_task(task, ctx)) {
        // Registration failed (registry full) - clean up and return NULL
        // Without task→context mapping, coverage writes after task hops go to wrong map
        free(ctx);
        return NULL;
    }

    // Pre-warm the cache by creating the coverage map now.
    // This avoids O(512) scans when sancov_reset_counters is called immediately after.
    if (g_guard_count > 0) {
        uint8_t* map = find_or_create_task_map(ctx);
        if (map != NULL) {
            // Store the slot index and map in the context for O(1) lookup after task hop
            ctx->slot_index = tls_cached_task_registry_slot;
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
        // Cache for next time
        ctx->slot_index = tls_cached_task_registry_slot;
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
        ctx->slot_index = tls_cached_task_registry_slot;
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

    // No measurement context - use the task's map directly
    if (task != NULL) {
        uint8_t* map = find_or_create_task_map(task);
        if (map != NULL) {
            // Cache for next time
            tls_cached_task = task;
            tls_cached_task_map = map;
            return map;
        }
    }

    // Fallback to thread-local storage when registry is full
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
