//
//  SanCovHooks.c
//  PropertyTestingKit
//
//  Implementation of LLVM SanitizerCoverage hooks for coverage-guided fuzzing.
//

#include "include/SanCovHooks.h"
#include <string.h>
#include <dlfcn.h>
#include <os/lock.h>

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

// Thread-local target context for schedule-aware coverage.
// Set per-thread so parallel sessions don't corrupt each other.
// Defined here (before first use in get_current_coverage_map) and
// set/cleared in sancov_set_target_context below.
static _Thread_local SanCovMeasurementContext* g_target_context = NULL;

// Key pointer for coverage inheritance task local. When set, child tasks
// inherit their parent's measurement context via Swift task locals.
static const void* g_coverage_inheritance_key = NULL;

// ABI constants (same as CScheduleHooks — duplicated to avoid cross-dependency)
#define SANCOV_TASK_LOCAL_HEAD_OFFSET 136
#define SANCOV_ITEM_KIND_VALUE 0
#define SANCOV_ITEM_KIND_VALUE_IN_GROUP 1
#define SANCOV_ITEM_KIND_PARENT_MARKER 2
#define SANCOV_ITEM_KIND_STOP_MARKER 3

static bool sancov_is_valid_pointer(const void *ptr) {
    uintptr_t p = (uintptr_t)ptr;
    return p >= 0x100000000ULL && p < 0x800000000000ULL;
}

/// Read the inherited measurement context from a task's task-local chain.
/// Returns NULL if no inheritance key is set or the task local is not found.
// Swift runtime function that looks up task locals with proper inheritance.
// Resolves via dlsym to avoid link-time dependency.
typedef void* (*TaskLocalValueLookupFn)(const void* key);
static TaskLocalValueLookupFn swift_task_localValueLookup_fn = NULL;
static bool swift_task_localValueLookup_resolved = false;

static SanCovMeasurementContext* read_inherited_context(void* task) {
    if (g_coverage_inheritance_key == NULL || task == NULL) return NULL;

    // Resolve the runtime function once
    if (!swift_task_localValueLookup_resolved) {
        swift_task_localValueLookup_fn = (TaskLocalValueLookupFn)dlsym(
            RTLD_DEFAULT, "swift_task_localValueGet");
        swift_task_localValueLookup_resolved = true;
    }
    if (!swift_task_localValueLookup_fn) return NULL;

    // Call the runtime's own lookup — handles parent-chain inheritance correctly.
    void* result = swift_task_localValueLookup_fn(g_coverage_inheritance_key);
    if (!result) return NULL;

    uintptr_t ctx_bits;
    memcpy(&ctx_bits, result, sizeof(ctx_bits));
    return (ctx_bits != 0) ? (SanCovMeasurementContext*)ctx_bits : NULL;
}

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

// Retain a measurement context (increment refcount)
static void ctx_retain(SanCovMeasurementContext* ctx) {
    if (ctx) {
        atomic_fetch_add(&ctx->refcount, 1);
    }
}

// Release a measurement context (decrement refcount, free if zero)
static void ctx_release(SanCovMeasurementContext* ctx) {
    if (ctx) {
        int old_count = atomic_fetch_sub(&ctx->refcount, 1);
        if (old_count == 1) {
            // Refcount dropped to zero, free the context
            cleanup_task_map(ctx);
            free(ctx->covered_indices);
            free(ctx);
        }
    }
}

// Helper to update TLS cached measurement context with proper refcounting
static void set_tls_measurement_context(SanCovMeasurementContext* new_ctx) {
    SanCovMeasurementContext* old_ctx = tls_cached_measurement_context;
    if (old_ctx != new_ctx) {
        ctx_retain(new_ctx);  // Retain new (NULL is safe)
        tls_cached_measurement_context = new_ctx;
        ctx_release(old_ctx); // Release old (NULL is safe)
    }
}

SanCovMeasurementContext* sancov_begin_measurement(void) {
    SanCovMeasurementContext* ctx = (SanCovMeasurementContext*)xmalloc(sizeof(SanCovMeasurementContext));
    ctx->coverage_map = NULL;
    ctx->covered_count = 0;
    // Pre-allocate covered index buffer (typical coverage is sparse, 64 is plenty for most iterations)
    ctx->covered_indices_capacity = 64;
    ctx->covered_indices = (uint32_t*)xmalloc(ctx->covered_indices_capacity * sizeof(uint32_t));
    ctx->path_trie = NULL;
    atomic_init(&ctx->refcount, 1);  // Start with refcount of 1 (owner reference)

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
            set_tls_measurement_context(ctx);
            tls_cached_coverage_map = map;
            tls_cached_task = task;
            tls_cached_task_map = map;
        }
    }

    return ctx;
}

SanCovMeasurementContext* sancov_create_dummy_context(void) {
    SanCovMeasurementContext* ctx = (SanCovMeasurementContext*)xmalloc(sizeof(SanCovMeasurementContext));
    ctx->coverage_map = NULL;
    ctx->covered_count = 0;
    ctx->covered_indices_capacity = 0;
    ctx->covered_indices = NULL;
    ctx->path_trie = NULL;
    atomic_init(&ctx->refcount, 1);
    return ctx;
}

/// Reset coverage for a measurement context (cheap memset, O(1) for covered_count).
/// Used between iterations in the fuzz loop to avoid hash table insert/remove overhead.
void sancov_reset_coverage(SanCovMeasurementContext* ctx) {
    if (ctx == NULL) return;

    if (ctx->coverage_map != NULL && g_guard_count > 0) {
        memset(ctx->coverage_map, 0, g_guard_count);
    }
    ctx->covered_count = 0;
    // covered_indices buffer is reused — just reset the count (capacity stays)

    // Also clear the TLS cached map so infrastructure edges outside g_target_context
    // are re-recorded on the next run (needed for correct trie path tracking).
    tls_cached_coverage_map = NULL;
    // Clear the per-task map from the hash table if it's different from the context map.
    // This handles edges that fire before/after g_target_context is set.
    if (tls_cached_task_map != NULL && tls_cached_task_map != ctx->coverage_map) {
        memset(tls_cached_task_map, 0, g_guard_count);
    }

    // Reset the trie if attached (move pointer back to root, clear novel flag)
    if (ctx->path_trie) {
        sancov_trie_reset(ctx->path_trie);
    }
}

/// Cleanup caches, etc
void sancov_end_measurement(SanCovMeasurementContext* ctx) {
    if (ctx == NULL) return;

    // Remove the measurement context from the current task
    void* task = get_current_task_for_measurement();
    remove_measurement_context_for_task(task);

    // Invalidate this thread's TLS cache if it matches
    // Note: Other threads may still hold TLS references - that's OK because
    // the refcount will keep the context alive until they release it.
    if (tls_cached_measurement_context == ctx) {
        set_tls_measurement_context(NULL);  // Releases our TLS reference
        tls_cached_coverage_map = NULL;
    }
    tls_cached_task = NULL;
    tls_cached_task_map = NULL;

    // Release the owner reference (context allocated with refcount=1)
    // The context will be freed when all TLS references are also released
    ctx_release(ctx);
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
const uint32_t* sancov_get_covered_indices(SanCovMeasurementContext* ctx, size_t* out_count) {
    if (!ctx || !out_count) {
        if (out_count) *out_count = 0;
        return NULL;
    }
    size_t count = ctx->covered_count;
    *out_count = count;
    if (count == 0 || !ctx->covered_indices) return NULL;
    return ctx->covered_indices;
}

// Scans the coverage map and returns indices of edges that were hit (counter != 0).
// The caller is responsible for freeing the returned array.
// Use sancov_get_covered_count_with_context() to get the array size.
//
// Returns:
//   Newly allocated array of covered indices, or NULL if none covered.
//   Caller must free() the returned pointer.
//
uint32_t* sancov_snapshot_covered_indices_with_context(SanCovMeasurementContext* ctx) {
    if (!ctx) return NULL;

    size_t count = ctx->covered_count;
    if (count == 0) return NULL;

    // Fast path: copy from covered indices buffer — O(covered_edges)
    if (ctx->covered_indices && count <= ctx->covered_indices_capacity) {
        uint32_t* indices = (uint32_t*)xmalloc(count * sizeof(uint32_t));
        memcpy(indices, ctx->covered_indices, count * sizeof(uint32_t));
        return indices;
    }

    // Fallback: scan counters
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

        uint64_t low = vgetq_lane_u64(cmp64, 0);
        uint64_t high = vgetq_lane_u64(cmp64, 1);

        // Skip entirely zero chunks (common case - coverage is sparse)
        if (low == 0 && high == 0) {
            continue;
        }

        // Extract non-zero indices using CTZ (count trailing zeros)
        // Each byte in cmp64 is either 0x00 or 0xFF, so CTZ gives bit position
        // Divide by 8 to get byte position within the chunk

        // Process low 8 bytes (indices 0-7 within chunk)
        while (low && filled < count) {
            int tz = __builtin_ctzll(low);
            int byte_pos = tz >> 3;  // tz / 8
            indices[filled++] = (uint32_t)(i + byte_pos);
            low &= ~(0xFFULL << (byte_pos << 3));  // Clear this byte
        }

        // Process high 8 bytes (indices 8-15 within chunk)
        while (high && filled < count) {
            int tz = __builtin_ctzll(high);
            int byte_pos = tz >> 3;
            indices[filled++] = (uint32_t)(i + 8 + byte_pos);
            high &= ~(0xFFULL << (byte_pos << 3));
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

// Helper: Check if bit is set in bitmap
static inline bool bitmap_contains(uint64_t* bitmap, size_t bitmap_word_count, uint32_t index) {
    size_t word_idx = index >> 6;  // index / 64
    if (word_idx >= bitmap_word_count) return false;
    uint64_t bit = 1ULL << (index & 63);  // index % 64
    return (bitmap[word_idx] & bit) != 0;
}

// Helper: Set bit in bitmap, return true if it was newly set
static inline bool bitmap_insert(uint64_t* bitmap, size_t bitmap_word_count, uint32_t index) {
    size_t word_idx = index >> 6;
    if (word_idx >= bitmap_word_count) return false;
    uint64_t bit = 1ULL << (index & 63);
    uint64_t old = bitmap[word_idx];
    if ((old & bit) != 0) return false;  // Already set
    bitmap[word_idx] = old | bit;
    return true;
}

// Compute signature hash from coverage data without allocation.
// This matches the SparseCoverage.signatureHash algorithm:
//   hash = XOR of (index * 0x9e3779b97f4a7c15) for each covered index
//   hash ^= count * 0x517cc1b727220a95
// Uses the same SIMD iteration as other coverage functions.
int64_t sancov_compute_hash_from_indices(const uint32_t* indices, size_t count) {
    if (!indices || count == 0) return 0;

    const int64_t INDEX_PRIME = 0x9e3779b97f4a7c15LL;
    const int64_t COUNT_PRIME = 0x517cc1b727220a95LL;

    int64_t hash = 0;
    for (size_t i = 0; i < count; i++) {
        int64_t mixed = (int64_t)indices[i] * INDEX_PRIME;
        hash ^= mixed;
    }
    hash ^= (int64_t)count * COUNT_PRIME;
    return hash;
}

int64_t sancov_compute_signature_hash(SanCovMeasurementContext* ctx) {
    if (!ctx) return 0;

    size_t count = ctx->covered_count;
    if (count == 0) return 0;

    // Fast path: use the covered indices buffer — O(covered_edges) not O(total_edges)
    if (ctx->covered_indices && count <= ctx->covered_indices_capacity) {
        return sancov_compute_hash_from_indices(ctx->covered_indices, count);
    }

    // Fallback: buffer overflow, scan counters (should be rare)
    const uint8_t* counters = get_counters_with_context(ctx);
    size_t counter_count = sancov_get_counter_count();
    if (!counters || counter_count == 0) return 0;

    const int64_t INDEX_PRIME = 0x9e3779b97f4a7c15LL;
    const int64_t COUNT_PRIME = 0x517cc1b727220a95LL;

    int64_t hash = 0;

    for (size_t i = 0; i < counter_count; i++) {
        if (counters[i] != 0) {
            int64_t mixed = (int64_t)i * INDEX_PRIME;
            hash ^= mixed;
        }
    }

    hash ^= (int64_t)count * COUNT_PRIME;
    return hash;
}

// Merge coverage from context directly into bitmap.
// Returns true if any new coverage was found.
// If merge_all is false, returns immediately on first new coverage.
// If merge_all is true, merges all coverage and returns whether any was new.
bool sancov_merge_coverage_into_bitmap(
    SanCovMeasurementContext* ctx,
    uint64_t* bitmap,
    size_t bitmap_word_count,
    bool merge_all
) {
    if (!ctx || !bitmap || bitmap_word_count == 0) return false;

    size_t count = ctx->covered_count;
    if (count == 0) return false;

    const uint8_t* counters = get_counters_with_context(ctx);
    size_t counter_count = sancov_get_counter_count();
    if (!counters || counter_count == 0) return false;

    bool found_new = false;

#if USE_NEON_SIMD

    size_t i = 0;
    uint8x16_t zero = vdupq_n_u8(0);

    for (; i + 16 <= counter_count; i += 16) {
        uint8x16_t chunk = vld1q_u8(counters + i);
        uint8x16_t cmp = vcgtq_u8(chunk, zero);
        uint64x2_t cmp64 = vreinterpretq_u64_u8(cmp);

        uint64_t low = vgetq_lane_u64(cmp64, 0);
        uint64_t high = vgetq_lane_u64(cmp64, 1);

        // Skip entirely zero chunks (common case - coverage is sparse)
        if (low == 0 && high == 0) {
            continue;
        }

        // Process low 8 bytes using CTZ
        while (low) {
            int tz = __builtin_ctzll(low);
            int byte_pos = tz >> 3;
            uint32_t index = (uint32_t)(i + byte_pos);

            if (bitmap_insert(bitmap, bitmap_word_count, index)) {
                if (!merge_all) return true;
                found_new = true;
            }
            low &= ~(0xFFULL << (byte_pos << 3));
        }

        // Process high 8 bytes
        while (high) {
            int tz = __builtin_ctzll(high);
            int byte_pos = tz >> 3;
            uint32_t index = (uint32_t)(i + 8 + byte_pos);

            if (bitmap_insert(bitmap, bitmap_word_count, index)) {
                if (!merge_all) return true;
                found_new = true;
            }
            high &= ~(0xFFULL << (byte_pos << 3));
        }
    }

    // Handle remaining bytes
    for (; i < counter_count; i++) {
        if (counters[i] != 0) {
            if (bitmap_insert(bitmap, bitmap_word_count, (uint32_t)i)) {
                if (!merge_all) return true;
                found_new = true;
            }
        }
    }

#else
    // Scalar fallback
    for (size_t i = 0; i < counter_count; i++) {
        if (counters[i] != 0) {
            if (bitmap_insert(bitmap, bitmap_word_count, (uint32_t)i)) {
                if (!merge_all) return true;
                found_new = true;
            }
        }
    }
#endif

    return found_new;
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
    // HIGHEST PRIORITY: schedule-aware target context.
    // When schedule fuzzing is active, ALL edge hits go to the engine's context
    // regardless of which task/thread they fire on.
    if (g_target_context != NULL) {
        // Route all edges to the target context. Set tls_cached_measurement_context
        // so the trie and covered_indices are maintained. Trie operations are
        // protected by g_trie_lock to handle concurrent access from pool threads.
        set_tls_measurement_context(g_target_context);
        tls_cached_coverage_map = g_target_context->coverage_map;
        return g_target_context->coverage_map;
    }

    // Get the current task (Swift task or sync pseudo-task)
    void* task = get_current_task_for_measurement();

#if !SANCOV_DISABLE_TLS_CACHE
    // FAST PATH: Check if we have a cached map for this exact task
    // This avoids the O(512) scans in the common case where the task hasn't changed
    if (task == tls_cached_task && tls_cached_task_map != NULL) {
        // When coverage inheritance is active, don't trust the cache for tasks
        // without a measurement context — they may have been cached to the TLS
        // fallback map before the inheritance key was set. Force re-lookup so
        // read_inherited_context gets a chance to route to the parent's map.
        if (g_coverage_inheritance_key != NULL && tls_cached_measurement_context == NULL) {
            // Fall through to full lookup
        } else {
            return tls_cached_task_map;
        }
    }
#endif

    // Task changed - need to do full lookup
    // First check for measurement context for this task (highest priority)
    SanCovMeasurementContext* measurement_ctx = (SanCovMeasurementContext*)get_measurement_context_for_task(task);
    // removed debug
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
            set_tls_measurement_context(measurement_ctx);  // Properly retain/release
            tls_cached_coverage_map = map;
            tls_cached_task = task;
            tls_cached_task_map = map;
            return map;
        }
    }

    // Check task-local inheritance: child tasks inherit their parent's
    // measurement context via a @TaskLocal propagated down the task tree.
    // This is O(n) in task-local chain length (~3-5 items) but only runs
    // once per child task per thread — subsequent hits use the TLS cache above.
    SanCovMeasurementContext* inherited = read_inherited_context(task);
    if (inherited != NULL && inherited->coverage_map != NULL) {
        // Write edges to the parent's map. Do NOT set tls_cached_measurement_context
        // to avoid trie/covered_indices races from concurrent child tasks.
        tls_cached_task = task;
        tls_cached_task_map = inherited->coverage_map;
        set_tls_measurement_context(NULL);
        return inherited->coverage_map;
    }

    // No measurement context - use thread-local storage directly
    // We don't create task-keyed entries in the hash table because they would
    // never be cleaned up (we don't have a hook for task completion).
    // TLS is fine here since coverage outside of measurements isn't isolated anyway.
    ensure_tls_coverage_map();
    tls_cached_task = task;
    tls_cached_task_map = tls_coverage_map;
    // Clear stale measurement context so sancov_record_edge doesn't append
    // edges from this task into another test's measurement context.
    set_tls_measurement_context(NULL);
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

// Forward declaration — implemented after trie types are defined
static void maybe_advance_trie(SanCovMeasurementContext* ctx, uint32_t edge_index);

__attribute__((noinline))
void sancov_record_edge(uint32_t *guard) {
    uint8_t* map = get_current_coverage_map();
    if (map && *guard < g_guard_count) {
        if (map[*guard] == 0) {
            map[*guard] = 1;
            SanCovMeasurementContext* ctx = tls_cached_measurement_context;
            if (ctx) {
                size_t idx = ctx->covered_count;
                ctx->covered_count = idx + 1;
                // Advance trie if attached (O(1) — just pointer chase + child lookup)
                maybe_advance_trie(ctx, *guard);
                // Append to covered indices buffer (grow if needed)
                if (idx < ctx->covered_indices_capacity) {
                    ctx->covered_indices[idx] = *guard;
                } else if (ctx->covered_indices) {
                    size_t new_cap = ctx->covered_indices_capacity * 2;
                    uint32_t* new_buf = (uint32_t*)realloc(ctx->covered_indices, new_cap * sizeof(uint32_t));
                    if (new_buf) {
                        ctx->covered_indices = new_buf;
                        ctx->covered_indices_capacity = new_cap;
                        new_buf[idx] = *guard;
                    }
                }
            }
        }
    }
}

__attribute__((noinline))
void sancov_record_edge_counting(uint32_t *guard) {
    uint8_t* map = get_current_coverage_map();
    if (map && *guard < g_guard_count) {
        uint8_t prev = map[*guard];
        if (prev == 0) {
            // First hit: record the edge index, same as binary
            map[*guard] = 1;
            SanCovMeasurementContext* ctx = tls_cached_measurement_context;
            if (ctx) {
                size_t idx = ctx->covered_count;
                ctx->covered_count = idx + 1;
                if (idx < ctx->covered_indices_capacity) {
                    ctx->covered_indices[idx] = *guard;
                } else if (ctx->covered_indices) {
                    size_t new_cap = ctx->covered_indices_capacity * 2;
                    uint32_t* new_buf = (uint32_t*)realloc(ctx->covered_indices, new_cap * sizeof(uint32_t));
                    if (new_buf) {
                        ctx->covered_indices = new_buf;
                        ctx->covered_indices_capacity = new_cap;
                        new_buf[idx] = *guard;
                    }
                }
            }
        } else if (prev < 255) {
            // Subsequent hit: saturating 8-bit increment
            map[*guard] = prev + 1;
        }
    }
}

// MARK: - Trie Edge Hook

// Trie node: children stored as a sorted array of (edge_index, child_pointer) pairs.
// For typical coverage (~10-50 unique edges per node), linear scan is faster than hash table.
typedef struct TrieNode {
    uint32_t *child_edges;          // Sorted array of edge indices
    struct TrieNode **child_nodes;  // Parallel array of child pointers
    uint16_t child_count;
    uint16_t child_capacity;
    bool is_terminal;
} TrieNode;

static TrieNode* trie_node_create(void) {
    TrieNode* node = (TrieNode*)xmalloc(sizeof(TrieNode));
    node->child_edges = NULL;
    node->child_nodes = NULL;
    node->child_count = 0;
    node->child_capacity = 0;
    node->is_terminal = false;
    return node;
}

static void trie_node_destroy(TrieNode* node) {
    if (!node) return;
    for (uint16_t i = 0; i < node->child_count; i++) {
        trie_node_destroy(node->child_nodes[i]);
    }
    free(node->child_edges);
    free(node->child_nodes);
    free(node);
}

// Find child for edge_index. Returns the child node or NULL.
static inline TrieNode* trie_node_find_child(TrieNode* node, uint32_t edge_index) {
    // Linear scan — fast for small child counts (typical: 1-5 children per node)
    for (uint16_t i = 0; i < node->child_count; i++) {
        if (node->child_edges[i] == edge_index) {
            return node->child_nodes[i];
        }
    }
    return NULL;
}

// Add a child for edge_index. Returns the new child node.
static TrieNode* trie_node_add_child(TrieNode* node, uint32_t edge_index) {
    if (node->child_count == node->child_capacity) {
        uint16_t new_cap = node->child_capacity == 0 ? 4 : node->child_capacity * 2;
        node->child_edges = (uint32_t*)realloc(node->child_edges, new_cap * sizeof(uint32_t));
        node->child_nodes = (TrieNode**)realloc(node->child_nodes, new_cap * sizeof(TrieNode*));
        node->child_capacity = new_cap;
    }
    TrieNode* child = trie_node_create();
    node->child_edges[node->child_count] = edge_index;
    node->child_nodes[node->child_count] = child;
    node->child_count++;
    return child;
}

// Path trie state
struct SanCovPathTrie {
    TrieNode* root;
    TrieNode* current;
    bool is_novel;
    SanCovMeasurementContext* owner_context; // Back-pointer for cleanup
};

// Lock protecting trie advancement. When g_target_context routes all threads'
// edges to one context, multiple pool threads can advance the same trie.
static os_unfair_lock g_trie_lock = OS_UNFAIR_LOCK_INIT;

// Advance trie on first-hit if context has one attached.
// Called from sancov_record_edge on every first-hit edge.
static bool g_trie_debug = false;

static void maybe_advance_trie(SanCovMeasurementContext* ctx, uint32_t edge_index) {
    SanCovPathTrie* trie = ctx->path_trie;
    if (!trie) return;
    if (g_trie_debug) {
        fprintf(stderr, "[trie-adv] edge=%u\n", edge_index);
    }

    os_unfair_lock_lock(&g_trie_lock);
    TrieNode* child = trie_node_find_child(trie->current, edge_index);
    if (child) {
        trie->current = child;
    } else {
        trie->current = trie_node_add_child(trie->current, edge_index);
        trie->is_novel = true;
    }
    os_unfair_lock_unlock(&g_trie_lock);
}

void sancov_context_set_trie(SanCovMeasurementContext* context, SanCovPathTrie* trie) {
    if (context) context->path_trie = trie;
    if (trie) trie->owner_context = context;
}

SanCovPathTrie* sancov_trie_create(void) {
    SanCovPathTrie* trie = (SanCovPathTrie*)xmalloc(sizeof(SanCovPathTrie));
    trie->root = trie_node_create();
    trie->current = trie->root;
    trie->is_novel = false;
    trie->owner_context = NULL;
    return trie;
}

void sancov_trie_destroy(SanCovPathTrie* trie) {
    if (!trie) return;
    // NULL out the context's pointer to prevent use-after-free
    if (trie->owner_context) {
        trie->owner_context->path_trie = NULL;
    }
    trie_node_destroy(trie->root);
    free(trie);
}


bool sancov_trie_is_unique_path(SanCovPathTrie* trie) {
    if (!trie) return false;
    if (trie->is_novel) return true;
    return !trie->current->is_terminal;
}

void sancov_trie_mark_terminal(SanCovPathTrie* trie) {
    if (trie) trie->current->is_terminal = true;
}

void sancov_trie_reset(SanCovPathTrie* trie) {
    if (!trie) return;
    trie->current = trie->root;
    trie->is_novel = false;
}

// Temporary dump functions for trie analysis
uintptr_t sancov_get_pc(size_t edge_index);

static const char* resolve_edge_symbol(uint32_t edge_index) {
    uintptr_t pc = sancov_get_pc(edge_index);
    if (pc == 0) return "?";
    Dl_info info;
    if (dladdr((void*)pc, &info) == 0 || !info.dli_sname) return "?";
    return info.dli_sname;
}

static void trie_dump_recursive(TrieNode* node, uint32_t* path_buf, int depth, int* path_count) {
    if (node->is_terminal) {
        fprintf(stderr, "  path %d (len=%d):\n", *path_count, depth);
        for (int i = 0; i < depth; i++) {
            fprintf(stderr, "    [%d] edge %u = %s\n", i, path_buf[i], resolve_edge_symbol(path_buf[i]));
        }
        (*path_count)++;
    }
    for (uint16_t i = 0; i < node->child_count; i++) {
        if (depth < 4096) {
            path_buf[depth] = node->child_edges[i];
            trie_dump_recursive(node->child_nodes[i], path_buf, depth + 1, path_count);
        }
    }
}

void sancov_trie_dump(SanCovPathTrie* trie) {
    if (!trie || !trie->root) {
        fprintf(stderr, "[trie] empty\n");
        return;
    }
    uint32_t* buf = (uint32_t*)malloc(4096 * sizeof(uint32_t));
    int count = 0;
    fprintf(stderr, "[trie] dumping all terminal paths:\n");
    trie_dump_recursive(trie->root, buf, 0, &count);
    fprintf(stderr, "[trie] total terminal paths: %d\n", count);
    free(buf);
}

void sancov_trie_set_debug(bool enable) { g_trie_debug = enable; }

void sancov_trie_advance(SanCovPathTrie* trie, uint32_t edge_index) {
    if (!trie) return;
    if (g_trie_debug) {
        fprintf(stderr, "[trie-adv] edge=%u\n", edge_index);
    }
    os_unfair_lock_lock(&g_trie_lock);
    TrieNode* child = trie_node_find_child(trie->current, edge_index);
    if (child) {
        trie->current = child;
    } else {
        trie->current = trie_node_add_child(trie->current, edge_index);
        trie->is_novel = true;
    }
    os_unfair_lock_unlock(&g_trie_lock);
}

__attribute__((noinline))
void sancov_record_edge_trie(uint32_t *guard) {
    uint8_t* map = get_current_coverage_map();
    if (!map || *guard >= g_guard_count) return;

    // Check first-hit and mark the map. Skip covered_indices bookkeeping —
    // the trie strategy doesn't need it (uniqueness comes from the trie, not post-hoc).
    if (map[*guard]) return;
    map[*guard] = 1;

    // Advance the trie on first hit only — loop-immune.
    SanCovMeasurementContext* ctx = tls_cached_measurement_context;
    if (!ctx) return;
    SanCovPathTrie* trie = ctx->path_trie;
    if (!trie) return;

    uint32_t edge_index = *guard;
    os_unfair_lock_lock(&g_trie_lock);
    TrieNode* child = trie_node_find_child(trie->current, edge_index);
    if (child) {
        trie->current = child;
    } else {
        trie->current = trie_node_add_child(trie->current, edge_index);
        trie->is_novel = true;
    }
    os_unfair_lock_unlock(&g_trie_lock);
}

// MARK: - Schedule-Aware Target Context

void sancov_set_target_context(SanCovMeasurementContext* context) {
    g_target_context = context;
}

// MARK: - Coverage Inheritance (Task-Local Propagation)

void sancov_set_coverage_inheritance_key(const void* key) {
    g_coverage_inheritance_key = key;
}

void* sancov_get_current_task(void) {
    if (swift_task_getCurrent != NULL) {
        return swift_task_getCurrent();
    }
    return NULL;
}

const void* sancov_capture_key_by_value(const void* task, uintptr_t expected_value) {
    if (!task) return NULL;

    const void* head;
    memcpy(&head, (const char*)task + SANCOV_TASK_LOCAL_HEAD_OFFSET, sizeof(head));
    if (!head || !sancov_is_valid_pointer(head)) return NULL;

    const void* current = head;
    for (int depth = 0; depth < 30 && current; depth++) {
        uintptr_t nextAndKind;
        memcpy(&nextAndKind, current, sizeof(nextAndKind));
        unsigned kind = nextAndKind & 0x3;

        if (kind == SANCOV_ITEM_KIND_VALUE || kind == SANCOV_ITEM_KIND_VALUE_IN_GROUP) {
            uintptr_t value;
            memcpy(&value, (const char*)current + 24, sizeof(value));
            if (value == expected_value) {
                const void* key;
                memcpy(&key, (const char*)current + 8, sizeof(key));
                return key;
            }
        }

        if (kind == SANCOV_ITEM_KIND_STOP_MARKER) break;

        uintptr_t nextPtr = nextAndKind & ~(uintptr_t)0x3;
        current = (nextPtr != 0 && sancov_is_valid_pointer((void*)nextPtr))
            ? (const void*)nextPtr : NULL;
    }
    return NULL;
}

void sancov_rebuild_covered_indices_from_map(SanCovMeasurementContext* ctx) {
    if (!ctx || !ctx->coverage_map) return;
    size_t count = 0;
    for (size_t i = 0; i < g_guard_count; i++) {
        if (ctx->coverage_map[i]) {
            if (count < ctx->covered_indices_capacity && ctx->covered_indices) {
                ctx->covered_indices[count] = (uint32_t)i;
            }
            count++;
        }
    }
    ctx->covered_count = count;
}

void sancov_record_edge_to_target(uint32_t *guard) {
    SanCovMeasurementContext* ctx = g_target_context;
    if (ctx && ctx->coverage_map && *guard < g_guard_count) {
        uint8_t* map = ctx->coverage_map;
        if (map[*guard] == 0) {
            map[*guard] = 1;
            size_t idx = ctx->covered_count;
            ctx->covered_count = idx + 1;
            // Also advance trie if attached
            if (ctx->path_trie) {
                sancov_trie_advance(ctx->path_trie, *guard);
            }
            // Append to covered indices buffer
            if (idx < ctx->covered_indices_capacity) {
                ctx->covered_indices[idx] = *guard;
            } else if (ctx->covered_indices) {
                size_t new_cap = ctx->covered_indices_capacity * 2;
                uint32_t* new_buf = (uint32_t*)realloc(ctx->covered_indices, new_cap * sizeof(uint32_t));
                if (new_buf) {
                    ctx->covered_indices = new_buf;
                    ctx->covered_indices_capacity = new_cap;
                    new_buf[idx] = *guard;
                }
            }
        }
    } else if (!ctx) {
        // No target context — fall back to normal recording
        sancov_record_edge(guard);
    }
}

// Edge hook function pointer — set by Swift via sancov_install_swift_hook().
// Before Swift init, falls back to sancov_record_edge directly.
static void (*g_edge_hook)(uint32_t*) = NULL;

void sancov_install_swift_hook(void (*hook)(uint32_t*)) {
    g_edge_hook = hook;
}

void __sanitizer_cov_trace_pc_guard(uint32_t *guard) {
    if (g_edge_hook) {
        g_edge_hook(guard);
    } else {
        sancov_record_edge(guard);
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

// MARK: - Edge Filter

static size_t g_filtered_count = 0;
static bool g_filter_applied = false;

/// Check if a mangled symbol name matches a compiler-generated pattern.
/// Returns true if the symbol should be filtered out.
bool sancov_is_compiler_generated(const char* sname) {
    if (!sname) return false;

    // Prefix checks: runtime internals
    if (strncmp(sname, "__swift_", 8) == 0) return true;
    if (strncmp(sname, "_swift_", 7) == 0) return true;

    size_t len = strlen(sname);
    if (len < 3) return false;

    // Suffix checks on mangled Swift names.
    // Two-character suffixes:
    const char* last2 = sname + len - 2;
    if (strcmp(last2, "Wl") == 0) return true;  // lazy protocol witness table accessor
    if (strcmp(last2, "WL") == 0) return true;  // lazy metadata accessor
    if (strcmp(last2, "Ma") == 0) return true;  // type metadata accessor (generic)

    // Three-character suffixes (WO + specifier):
    if (len >= 3) {
        const char* last3 = sname + len - 3;
        if (strncmp(last3, "WO", 2) == 0) return true;  // all outlined operations (WOh/c/d/r/b/e/...)
    }

    // Two-character suffixes for other compiler-generated patterns:
    if (strcmp(last2, "TA") == 0) return true;  // partial apply forwarder
    if (strcmp(last2, "TR") == 0) return true;  // reabstraction thunk
    if (strcmp(last2, "TK") == 0) return true;  // key path getter
    if (strcmp(last2, "Mr") == 0) return true;  // type metadata completion

    // Async resume/suspend of compiler-generated thunks:
    // e.g. ...TRTATQ0_ (resume of partial apply of reabstraction thunk)
    if (strstr(sname, "TATQ") != NULL) return true;
    if (strstr(sname, "TATY") != NULL) return true;
    if (strstr(sname, "TRTQ") != NULL) return true;
    if (strstr(sname, "TRTY") != NULL) return true;

    // Global/static variable addressors: ends with "vau" (unsigned addressor)
    // These have init-once semantics with different branches for first vs cached access.
    if (len >= 3) {
        const char* last3 = sname + len - 3;
        if (last3[0] == 'v' && last3[1] == 'a' && last3[2] == 'u') return true;
    }

    // Bare async resume/yield points: ends with TQ<digit(s)>_ or TY<digit(s)>_
    // e.g. ...FTQ3_, ...FTY4_, ...cfU_TQ0_, ...cfU_TY1_
    // These continuation edges are scheduling-dependent — even under
    // ScheduleController.run (deterministic task ordering), the "which resume
    // point fires first" order can vary because two continuations may be
    // enqueued in whichever order the dependency-resolution happened to pick.
    // Filtering them is required for pathTrie-based determinism.
    if (len >= 4) {
        const char* p = sname + len - 1;
        if (*p == '_') {
            p--;
            // Skip digits
            while (p > sname && *p >= '0' && *p <= '9') p--;
            // Check for TQ or TY
            if (p >= sname + 1 && *p == 'Q' && *(p-1) == 'T') return true;
            if (p >= sname + 1 && *p == 'Y' && *(p-1) == 'T') return true;
        }
    }

    // Default argument: ends with fA<digit>_ (e.g. fA_, fA0_, fA1_)
    if (len >= 3) {
        // Check fA_ (no digit)
        const char* last3 = sname + len - 3;
        if (last3[0] == 'f' && last3[1] == 'A' && last3[2] == '_') return true;
        // Check fA<digit>_ (4-char pattern)
        if (len >= 4) {
            const char* last4 = sname + len - 4;
            if (last4[0] == 'f' && last4[1] == 'A' && last4[3] == '_') return true;
        }
    }

    return false;
}

void sancov_apply_edge_filter(void) {
    if (g_filter_applied) return;
    if (!g_guards_start || g_guard_count == 0) return;
    if (!g_pcs_start || g_pcs_count == 0) return;

    size_t filtered = 0;
    size_t limit = g_guard_count < g_pcs_count ? g_guard_count : g_pcs_count;

    for (size_t i = 0; i < limit; i++) {
        // PC table format: pairs of (PC, flags)
        uintptr_t pc = g_pcs_start[i * 2];
        if (pc == 0) continue;

        Dl_info info;
        if (dladdr((void*)pc, &info) == 0) continue;
        if (!info.dli_sname) continue;

        if (sancov_is_compiler_generated(info.dli_sname)) {
            g_guards_start[i] = SANCOV_GUARD_SKIP;
            filtered++;
        }
    }

    g_filtered_count = filtered;
    g_filter_applied = true;
}

size_t sancov_get_filtered_count(void) {
    return g_filtered_count;
}
