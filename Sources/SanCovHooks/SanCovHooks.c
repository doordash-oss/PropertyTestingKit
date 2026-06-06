// Copyright 2026 DoorDash, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

//  Implementation of LLVM SanitizerCoverage hooks for coverage-guided fuzzing.
//

#include "include/SanCovHooks.h"
#include <string.h>
#include <dlfcn.h>
#include <os/lock.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <pthread.h>

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
// inherit their parent's measurement context via Swift task locals. Atomic
// because it is written once by sancov_set_coverage_inheritance_key while being
// read concurrently on the per-edge hot path (TSan-confirmed race otherwise).
static _Atomic(const void*) g_coverage_inheritance_key = NULL;

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

// Active measurement-context registry. Used as a value-matching fallback in the
// chain walk when the captured @TaskLocal key lookup fails. The chain stores
// `UInt(bitPattern: ctx.rawContext)` for CoverageInheritance.context, so a
// chain ValueItem whose 64-bit value field matches a registered context pointer
// reliably identifies the inheriting context — without needing a correct key
// match. This is robust to any path that leaves `g_coverage_inheritance_key`
// stale or unset (and to any case where swift_task_localValueGet returns NULL
// even though the value is in the chain).
//
// The registry is backed by the same resizable lock-free hash table (ck_ht)
// used for the per-task coverage/measurement registries — keyed by the context
// pointer, membership == "currently live". A hash set (rather than the former
// fixed-size array) removes the capacity ceiling: under the parallel test suite
// many stress tests each hold dozens of live contexts at once, and a fixed cap
// silently dropped registrations, which made the liveness gate reject *live*
// contexts and silently lose their child-task coverage. The hash table grows on
// demand, so no live context is ever dropped, and reads stay lock-free (the
// routing hook is on the per-edge hot path).
//
// Implementations live below `init_active_ctx_ht` (after the ck_ht
// infrastructure is declared); these are forward declarations so the task-local
// walk above can call the liveness oracle.
static bool is_active_inheritance_context(SanCovMeasurementContext* candidate);
static void register_active_inheritance_context(SanCovMeasurementContext* ctx);
static void unregister_active_inheritance_context(SanCovMeasurementContext* ctx);

// Coverage-inheritance handle layout (see sancov_inheritance_handle below): the
// low 48 bits hold the context pointer and the high 16 bits hold its generation
// tag. Defined here so the task-local walk just below can decode handles.
#define SANCOV_HANDLE_PTR_BITS 48
#define SANCOV_HANDLE_PTR_MASK (((uint64_t)1 << SANCOV_HANDLE_PTR_BITS) - 1)
static inline SanCovMeasurementContext* sancov_handle_pointer(uint64_t handle) {
    return (SanCovMeasurementContext*)(uintptr_t)(handle & SANCOV_HANDLE_PTR_MASK);
}
static inline uint16_t sancov_handle_generation(uint64_t handle) {
    return (uint16_t)(handle >> SANCOV_HANDLE_PTR_BITS);
}

/// Read the inherited measurement context from a task's task-local chain.
/// Returns NULL if no inheritance key is set or the task local is not found.
// Swift runtime function that looks up task locals with proper inheritance.
// Resolves via dlsym to avoid link-time dependency. Resolved exactly once via
// pthread_once: the previous lazy `if (!resolved) { ... }` was read/written
// concurrently on the per-edge hot path (TSan-confirmed race); pthread_once
// gives a race-free, happens-before-correct one-time init.
typedef void* (*TaskLocalValueLookupFn)(const void* key);
static TaskLocalValueLookupFn swift_task_localValueLookup_fn = NULL;
static pthread_once_t swift_task_localValueLookup_once = PTHREAD_ONCE_INIT;
static void resolve_swift_task_localValueLookup(void) {
    swift_task_localValueLookup_fn =
        (TaskLocalValueLookupFn)dlsym(RTLD_DEFAULT, "swift_task_localValueGet");
}

/// Manual walk of the task-local chain. Returns the generation-tagged
/// inheritance HANDLE stored under the CoverageInheritance.context key (0 if
/// none). Two paths are checked at each ValueItem: (1) the captured
/// CoverageInheritance.context key, and (2) any value whose decoded pointer is a
/// registered active measurement context. (2) does not require
/// g_coverage_inheritance_key to be set, and is the load-bearing path when the
/// captured key is absent or stale. The caller resolves and validates the
/// returned handle via retain_inherited_if_valid (liveness + generation check).
///
/// Walks ParentTaskMarker links transparently — the marker's `next` field is
/// set by the runtime at task creation to point into the parent's chain, so
/// following `next` continues into parent-task locals as expected. STOP
/// markers terminate the walk.
static uint64_t manual_walk_for_inherited_context(const void* task) {
    if (!task) return 0;

    const void* head;
    memcpy(&head, (const char*)task + SANCOV_TASK_LOCAL_HEAD_OFFSET, sizeof(head));
    if (!head || !sancov_is_valid_pointer(head)) return 0;

    const void* current = head;
    for (int depth = 0; depth < 100 && current; depth++) {
        uintptr_t nextAndKind;
        memcpy(&nextAndKind, current, sizeof(nextAndKind));
        unsigned kind = nextAndKind & 0x3;

        if (kind == SANCOV_ITEM_KIND_VALUE || kind == SANCOV_ITEM_KIND_VALUE_IN_GROUP) {
            const void* key;
            memcpy(&key, (const char*)current + 8, sizeof(key));
            uint64_t handle;
            memcpy(&handle, (const char*)current + 24, sizeof(handle));

            // Path 1: precise key match (when captureKeyIfNeeded set the key).
            if (g_coverage_inheritance_key != NULL &&
                key == g_coverage_inheritance_key &&
                handle != 0) {
                return handle;
            }

            // Path 2: handle whose decoded pointer is a registered active
            // measurement context. Covers an unset or stale captured key (both
            // empirically observed under concurrent test load). The decoded
            // pointer must be valid and currently registered, so spurious
            // matches against unrelated @TaskLocals (whose values do not decode
            // to live measurement-context pointers) are excluded; the caller's
            // generation check rejects any residual address-recycling match.
            if (handle != 0) {
                SanCovMeasurementContext* candidate = sancov_handle_pointer(handle);
                if (sancov_is_valid_pointer(candidate) &&
                    is_active_inheritance_context(candidate)) {
                    return handle;
                }
            }
        } else if (kind == SANCOV_ITEM_KIND_STOP_MARKER) {
            break;
        }

        uintptr_t nextPtr = nextAndKind & ~(uintptr_t)0x3;
        current = (nextPtr != 0 && sancov_is_valid_pointer((void*)nextPtr))
            ? (const void*)nextPtr : NULL;
    }
    return 0;
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
//
// CONCURRENCY: ck_ht's *_spmc API is single-producer — concurrent writers, and
// readers racing a resize that frees the old map, are data races (confirmed by
// ThreadSanitizer). begin/end_measurement run on many threads at once under the
// parallel test suite, so every table is guarded by a pthread_rwlock: readers
// (ck_ht_get) take the shared lock; writers (set/put/remove, which also drive
// resize) take the exclusive lock. This makes writes single-producer and keeps
// the resize-time free from running concurrently with any reader. The locks are
// per-table and never nested, so there is no lock-ordering hazard.

// Coverage registry: task_id -> coverage_map
static ck_ht_t g_coverage_ht;
static pthread_once_t g_coverage_ht_once = PTHREAD_ONCE_INIT;
static pthread_rwlock_t g_coverage_ht_lock = PTHREAD_RWLOCK_INITIALIZER;

// Active-context liveness set: live measurement context pointer -> itself.
// Membership means the context is currently between begin/end_measurement (i.e.
// safe to route inherited edges to). Resizable, so it never overflows.
static ck_ht_t g_active_ctx_ht;
static pthread_once_t g_active_ctx_ht_once = PTHREAD_ONCE_INIT;
static pthread_rwlock_t g_active_ctx_ht_lock = PTHREAD_RWLOCK_INITIALIZER;

// Bumped on every register/unregister, i.e. whenever the set of live measurement
// contexts changes. The per-edge hot path caches its resolved coverage map per
// thread and, while inheritance is active, trusts that cache only as long as the
// epoch is unchanged: an unchanged epoch means no measurement has begun or ended
// since the cache was filled, so the cached context is still the right one AND
// still alive (so the routing dereference is safe WITHOUT re-taking the liveness
// lock or a reference). Any begin/end forces a full, lock-protected re-resolve.
static _Atomic uint64_t g_active_ctx_epoch = 0;

// MARK: - Coverage-inheritance handle (generation-tagged pointer)
//
// The value stored in the CoverageInheritance.context task-local is NOT a raw
// context pointer. It is a generation-tagged HANDLE: the low 48 bits hold the
// context pointer and the high 16 bits hold the context's `generation` tag
// (assigned monotonically at begin_measurement). Routing decodes the pointer to
// locate the context, then — after the liveness retain — verifies the live
// context's generation matches the handle's. A straggler whose captured address
// was freed and recycled by a later, unrelated measurement therefore fails the
// generation check (the new context has a different tag) and is rejected,
// closing the ABA cross-measurement contamination. arm64/x86_64 user pointers
// fit in 48 bits, so no pointer information is lost (asserted at handle build).
// (SANCOV_HANDLE_PTR_* macros and the decode helpers are defined near the top,
// before the task-local walk that consumes handles.)
static _Atomic uint64_t g_next_generation = 1;  // 0 reserved; tag is low 16 bits

uint64_t sancov_inheritance_handle(SanCovMeasurementContext* context) {
    if (context == NULL) return 0;
    uintptr_t ptr = (uintptr_t)context;
    if ((ptr & ~SANCOV_HANDLE_PTR_MASK) != 0) {
        // A context pointer outside the low 48 bits would corrupt the packed
        // generation tag. Not expected on supported targets; fail loud.
        fprintf(stderr, "FATAL: context pointer %p does not fit in %d bits\n",
                (void*)context, SANCOV_HANDLE_PTR_BITS);
        abort();
    }
    return ((uint64_t)context->generation << SANCOV_HANDLE_PTR_BITS)
         | ((uint64_t)ptr & SANCOV_HANDLE_PTR_MASK);
}

// Resolve an inheritance handle to a LIVE, generation-matched context, retained.
// Returns the retained context (caller MUST ctx_release) iff the handle's
// pointer is currently registered active AND its generation tag still matches
// the live context — otherwise NULL. Combines the TOCTOU-safe liveness retain
// (review #52) with the ABA generation check (review #53/#56).
static SanCovMeasurementContext* retain_inherited_if_valid(uint64_t handle);

// Defined further below (after the refcount helpers); forward-declared so the
// testing seams above can reset the calling thread's cached measurement context.
static void set_tls_measurement_context(SanCovMeasurementContext* new_ctx);

// Thread-local fallback for non-async contexts
static _Thread_local uint8_t *tls_coverage_map = NULL;

// Measurement registry: task_id -> measurement_context
static ck_ht_t g_measurement_ht;
static pthread_once_t g_measurement_ht_once = PTHREAD_ONCE_INIT;
static pthread_rwlock_t g_measurement_ht_lock = PTHREAD_RWLOCK_INITIALIZER;

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

// Silent diagnostic counters tracking which path resolved get_current_coverage_map.
// Enabled per-test by tests that want to verify routing behavior. No fprintf,
// pure atomics — no risk of stderr flooding or impacting other concurrent tests.
static _Atomic uint64_t g_route_target_ctx = 0;
static _Atomic uint64_t g_route_tls_cache_inheritance_active = 0;
static _Atomic uint64_t g_route_inherited_runtime = 0;
static _Atomic uint64_t g_route_inherited_manualwalk = 0;
static _Atomic uint64_t g_route_per_task_registry = 0;
static _Atomic uint64_t g_route_tls_fallback_inheritance_active = 0;
static _Atomic uint64_t g_route_tls_fallback_no_inheritance = 0;

// Sub-categorization of tls_fallback_inheritance_active. Set when a routing
// call reaches TLS fallback even though some inheritance scope is live.
//   - sync_pseudo_task:  swift_task_getCurrent() returned NULL — synchronous
//                        code firing edges; no chain to walk.
//   - real_task_no_head: real task, head at offset 136 is NULL — empty chain.
//   - real_task_no_match: real task, head non-NULL, walked the chain but
//                         neither captured key nor active-context value found.
//                         This is the bucket that would indicate a real
//                         routing bug (a task that SHOULD have inherited but
//                         the chain didn't carry the value through).
static _Atomic uint64_t g_route_tlsfb_sync_pseudo_task = 0;
static _Atomic uint64_t g_route_tlsfb_real_task_no_head = 0;
static _Atomic uint64_t g_route_tlsfb_real_task_no_match = 0;

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

static void init_active_ctx_ht(void) {
    ck_ht_init(&g_active_ctx_ht, CK_HT_MODE_DIRECT, NULL, &ck_allocator, CK_HT_INITIAL_CAPACITY, 0);
}

static inline void ensure_active_ctx_ht(void) {
    pthread_once(&g_active_ctx_ht_once, init_active_ctx_ht);
}

// MARK: - Active-Context Liveness Set (ck_ht-backed; see forward decls above)

// Liveness oracle: a candidate measurement context is only safe to route to
// while it is still registered (between begin_measurement's register and
// end_measurement's unregister, which happens BEFORE the context is freed).
// Lock-free read; compares the candidate pointer as a hash key only — it never
// dereferences `candidate`, so it is safe to call with an already-freed pointer.
static bool is_active_inheritance_context(SanCovMeasurementContext* candidate) {
    if (candidate == NULL) return false;
    ensure_active_ctx_ht();

    ck_ht_entry_t entry;
    ck_ht_hash_t h;
    ck_ht_hash_direct(&h, &g_active_ctx_ht, (uintptr_t)candidate);
    ck_ht_entry_key_set_direct(&entry, (uintptr_t)candidate);
    pthread_rwlock_rdlock(&g_active_ctx_ht_lock);
    bool found = ck_ht_get_spmc(&g_active_ctx_ht, h, &entry);
    pthread_rwlock_unlock(&g_active_ctx_ht_lock);
    return found;
}

static void register_active_inheritance_context(SanCovMeasurementContext* ctx) {
    if (ctx == NULL) return;
    ensure_active_ctx_ht();

    ck_ht_entry_t entry;
    ck_ht_hash_t h;
    ck_ht_hash_direct(&h, &g_active_ctx_ht, (uintptr_t)ctx);
    // Value is the pointer itself (must be non-zero); only membership matters.
    ck_ht_entry_set_direct(&entry, h, (uintptr_t)ctx, (uintptr_t)ctx);
    pthread_rwlock_wrlock(&g_active_ctx_ht_lock);
    ck_ht_put_spmc(&g_active_ctx_ht, h, &entry);
    pthread_rwlock_unlock(&g_active_ctx_ht_lock);
    // Invalidate every thread's hot-path cache: a new live context exists.
    atomic_fetch_add_explicit(&g_active_ctx_epoch, 1, memory_order_release);
}

static void unregister_active_inheritance_context(SanCovMeasurementContext* ctx) {
    if (ctx == NULL) return;
    ensure_active_ctx_ht();

    ck_ht_entry_t entry;
    ck_ht_hash_t h;
    ck_ht_hash_direct(&h, &g_active_ctx_ht, (uintptr_t)ctx);
    ck_ht_entry_key_set_direct(&entry, (uintptr_t)ctx);
    pthread_rwlock_wrlock(&g_active_ctx_ht_lock);
    ck_ht_remove_spmc(&g_active_ctx_ht, h, &entry);
    pthread_rwlock_unlock(&g_active_ctx_ht_lock);
    // Invalidate every thread's hot-path cache: a context just stopped being live,
    // so any cache that resolved to it must be re-validated before the next deref.
    atomic_fetch_add_explicit(&g_active_ctx_epoch, 1, memory_order_release);
}

// MARK: - Measurement Context Registry Operations (lock-free with ck_ht)

// Get measurement context for a task (lock-free lookup)
static void* get_measurement_context_for_task(void* task_id) {
    ensure_measurement_ht();

    ck_ht_entry_t entry;
    ck_ht_hash_t h;

    ck_ht_hash_direct(&h, &g_measurement_ht, (uintptr_t)task_id);
    ck_ht_entry_key_set_direct(&entry, (uintptr_t)task_id);

    pthread_rwlock_rdlock(&g_measurement_ht_lock);
    bool found = ck_ht_get_spmc(&g_measurement_ht, h, &entry);
    pthread_rwlock_unlock(&g_measurement_ht_lock);
    if (found) {
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

    pthread_rwlock_wrlock(&g_measurement_ht_lock);
    bool ok = ck_ht_set_spmc(&g_measurement_ht, h, &entry);
    pthread_rwlock_unlock(&g_measurement_ht_lock);
    return ok;
}

// Remove measurement context for a task (lock-free write)
static void remove_measurement_context_for_task(void* task_id) {
    ensure_measurement_ht();

    ck_ht_entry_t entry;
    ck_ht_hash_t h;

    ck_ht_hash_direct(&h, &g_measurement_ht, (uintptr_t)task_id);
    ck_ht_entry_key_set_direct(&entry, (uintptr_t)task_id);

    pthread_rwlock_wrlock(&g_measurement_ht_lock);
    ck_ht_remove_spmc(&g_measurement_ht, h, &entry);
    pthread_rwlock_unlock(&g_measurement_ht_lock);
}

// TESTING ONLY (see header): mark a context "ended" for routing purposes —
// drop it from BOTH the active-inheritance liveness set and the per-task
// measurement registry (exactly what sancov_end_measurement does) but DO NOT
// free it, so a test can read its coverage afterward. Must be called from the
// same task that began the measurement (matches end_measurement's contract).
void sancov_unregister_inheritance_for_testing(SanCovMeasurementContext* context) {
    unregister_active_inheritance_context(context);
    remove_measurement_context_for_task(get_current_task_for_measurement());
}

// TESTING ONLY (see header): drop just the current task's measurement-registry
// entry; leave the active-inheritance set and the context allocation untouched.
// Bumps the liveness epoch so every thread's hot-path cache is invalidated —
// otherwise the owning thread's cached map pointer would keep routing the
// owning task's edges into the context after the registry entry is gone.
void sancov_remove_task_measurement_for_testing(void) {
    remove_measurement_context_for_task(get_current_task_for_measurement());
    // Clear this thread's hot-path cache so a stale cached map pointer can't keep
    // routing the owning task's edges into the (now-deregistered) context. The
    // epoch bump covers inheritance-active readers; clearing the TLS cache also
    // covers the !inheritance_active fast-path short-circuit (which ignores the
    // epoch). Mirrors the cache teardown in sancov_end_measurement.
    set_tls_measurement_context(NULL);
    tls_cached_task = NULL;
    tls_cached_task_map = NULL;
    tls_cached_coverage_map = NULL;
    atomic_fetch_add_explicit(&g_active_ctx_epoch, 1, memory_order_release);
}

// MARK: - Coverage Map Registry Operations (lock-free with ck_ht)

// Find or create a coverage map for the given task
// Lock-free: uses ck_ht_put_spmc which only inserts if key doesn't exist
static uint8_t* find_or_create_task_map(void* task_id) {
    if (task_id == NULL || g_guard_count == 0) return NULL;

    ensure_coverage_ht();

    ck_ht_entry_t entry;
    ck_ht_hash_t h;

    // Fast path: shared-lock lookup for the common (already-exists) case.
    ck_ht_hash_direct(&h, &g_coverage_ht, (uintptr_t)task_id);
    ck_ht_entry_key_set_direct(&entry, (uintptr_t)task_id);

    pthread_rwlock_rdlock(&g_coverage_ht_lock);
    bool found = ck_ht_get_spmc(&g_coverage_ht, h, &entry);
    pthread_rwlock_unlock(&g_coverage_ht_lock);
    if (found) {
        return (uint8_t*)ck_ht_entry_value_direct(&entry);
    }

    // Need to insert - allocate new coverage map
    uint8_t* new_map = (uint8_t*)calloc(g_guard_count, 1);
    if (new_map == NULL) {
        return NULL;
    }

    // Slow path: take the exclusive lock, re-check (another writer may have
    // inserted between the rdlock release and now), then insert.
    pthread_rwlock_wrlock(&g_coverage_ht_lock);
    ck_ht_entry_key_set_direct(&entry, (uintptr_t)task_id);
    if (ck_ht_get_spmc(&g_coverage_ht, h, &entry)) {
        pthread_rwlock_unlock(&g_coverage_ht_lock);
        free(new_map);
        return (uint8_t*)ck_ht_entry_value_direct(&entry);
    }
    ck_ht_entry_set_direct(&entry, h, (uintptr_t)task_id, (uintptr_t)new_map);
    ck_ht_put_spmc(&g_coverage_ht, h, &entry);
    pthread_rwlock_unlock(&g_coverage_ht_lock);

    return new_map;
}

// Remove a task's coverage map entry (lock-free write)
static void cleanup_task_map(void* task_id) {
    ensure_coverage_ht();

    ck_ht_entry_t entry;
    ck_ht_hash_t h;

    ck_ht_hash_direct(&h, &g_coverage_ht, (uintptr_t)task_id);
    ck_ht_entry_key_set_direct(&entry, (uintptr_t)task_id);

    pthread_rwlock_wrlock(&g_coverage_ht_lock);
    bool removed = ck_ht_remove_spmc(&g_coverage_ht, h, &entry);
    pthread_rwlock_unlock(&g_coverage_ht_lock);

    if (removed) {
        // Entry was found and removed - free the coverage map. Safe to free
        // outside the lock: the entry is no longer reachable via the table.
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

// Break the bidirectional context<->trie link as the context is being freed, so
// a trie that outlives this context never writes through a dangling
// owner_context in sancov_trie_destroy. Defined below (needs the SanCovPathTrie
// definition and g_trie_lock); performs the unlink under g_trie_lock.
static void detach_trie_from_dying_context(SanCovMeasurementContext* ctx);

// Release a measurement context (decrement refcount, free if zero)
static void ctx_release(SanCovMeasurementContext* ctx) {
    if (ctx) {
        int old_count = atomic_fetch_sub(&ctx->refcount, 1);
        if (old_count == 1) {
            // Refcount dropped to zero, free the context. First sever the link
            // with any attached trie: clear our forward pointer AND the trie's
            // back-pointer to us, so a later trie destroy can't dereference this
            // freed context (the root cause of the parallel-fuzz heap corruption).
            detach_trie_from_dying_context(ctx);
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

// Liveness gate WITH a safe retain, closing the TOCTOU between the membership
// check and the dereference (review #52). Returns true and leaves `ctx`
// retained (the caller MUST ctx_release it) iff `ctx` was registered as active
// at the time of the check.
//
// Correctness: sancov_end_measurement unregisters a context (which takes the
// active-ctx WRITE lock) STRICTLY BEFORE it drops the owner reference / frees
// the context. By holding the READ lock across both the membership test and the
// ctx_retain, we guarantee that if the context is still registered, unregister
// (and therefore the free) cannot have run yet — so the context is alive and the
// retain is safe. After this returns true the caller holds a reference, so the
// context cannot be freed out from under the subsequent dereference. The retain
// itself is a bare atomic increment (no nested lock), so no lock-ordering hazard
// is introduced. Never dereferences `ctx` unless it is provably alive.
static bool retain_if_active_inheritance_context(SanCovMeasurementContext* ctx) {
    if (ctx == NULL) return false;
    ensure_active_ctx_ht();

    ck_ht_entry_t entry;
    ck_ht_hash_t h;
    ck_ht_hash_direct(&h, &g_active_ctx_ht, (uintptr_t)ctx);
    ck_ht_entry_key_set_direct(&entry, (uintptr_t)ctx);

    pthread_rwlock_rdlock(&g_active_ctx_ht_lock);
    bool found = ck_ht_get_spmc(&g_active_ctx_ht, h, &entry);
    if (found) {
        ctx_retain(ctx);  // safe: still registered ⇒ not yet unregistered ⇒ alive
    }
    pthread_rwlock_unlock(&g_active_ctx_ht_lock);
    return found;
}

static SanCovMeasurementContext* retain_inherited_if_valid(uint64_t handle) {
    if (handle == 0) return NULL;
    SanCovMeasurementContext* ctx = sancov_handle_pointer(handle);
    // Liveness gate + retain: guarantees `ctx` is alive (and stays alive) so the
    // generation read below cannot touch freed memory.
    if (!retain_if_active_inheritance_context(ctx)) return NULL;
    // ABA check: the address is live, but is it still the SAME context the
    // handle was minted from? A recycled address carries a different generation.
    if (ctx->generation != sancov_handle_generation(handle)) {
        ctx_release(ctx);
        return NULL;
    }
    return ctx;
}

SanCovMeasurementContext* sancov_begin_measurement(void) {
    SanCovMeasurementContext* ctx = (SanCovMeasurementContext*)xmalloc(sizeof(SanCovMeasurementContext));
    ctx->coverage_map = NULL;
    ctx->covered_count = 0;
    // Generation tag for the inheritance handle. Monotonic (mod 2^16); two
    // contexts that share a tag are >= 65536 begin_measurement calls apart, far
    // beyond the lifetime of any straggler that could alias a recycled address.
    ctx->generation = (uint16_t)atomic_fetch_add_explicit(&g_next_generation, 1, memory_order_relaxed);
    // Pre-allocate covered index buffer to g_guard_count so concurrent child
    // task writes (under CoverageInheritance) never trigger realloc races.
    // A realloc racing with another thread's append would be a use-after-free.
    size_t initial_cap = g_guard_count > 64 ? g_guard_count : 64;
    ctx->covered_indices_capacity = initial_cap;
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

    // Register this context in the inheritance registry so the chain walk in
    // get_current_coverage_map can match by value pointer when the captured
    // key path fails. Removed in sancov_end_measurement.
    register_active_inheritance_context(ctx);

    return ctx;
}

SanCovMeasurementContext* sancov_create_dummy_context(void) {
    SanCovMeasurementContext* ctx = (SanCovMeasurementContext*)xmalloc(sizeof(SanCovMeasurementContext));
    ctx->coverage_map = NULL;
    ctx->covered_count = 0;
    ctx->generation = (uint16_t)atomic_fetch_add_explicit(&g_next_generation, 1, memory_order_relaxed);
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

    // Clear the calling thread's TLS-cached coverage map pointer so the next
    // edge that fires on this thread re-routes through get_current_coverage_map.
    tls_cached_coverage_map = NULL;
    // We deliberately do NOT memset whatever bitmap `tls_cached_task_map` points
    // at. Under parallel test execution that pointer can target another active
    // test's coverage_map (a worker thread previously executed a child task
    // whose routing populated the cache, then was reassigned to this iteration
    // before any edge fired to refresh the cache). Wiping it silently dropped
    // coverage in foreign concurrent measurements (parallelEngineIsolation).

    // Reset the trie if attached (move pointer back to root, clear novel flag)
    if (ctx->path_trie) {
        sancov_trie_reset(ctx->path_trie);
    }
}

/// Cleanup caches, etc
void sancov_end_measurement(SanCovMeasurementContext* ctx) {
    if (ctx == NULL) return;

    // Drop the inheritance registration first so concurrent routing decisions
    // stop matching this context by value pointer before we tear it down.
    unregister_active_inheritance_context(ctx);

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
    // Atomic load: covered_count is bumped via __atomic_fetch_add on edge-firing
    // threads, so a plain read here is a data race (TSan-confirmed).
    return __atomic_load_n(&ctx->covered_count, __ATOMIC_RELAXED);
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
        atomic_fetch_add_explicit(&g_route_target_ctx, 1, memory_order_relaxed);
        // Route all edges to the target context. Set tls_cached_measurement_context
        // so the trie and covered_indices are maintained. Trie operations are
        // protected by g_trie_lock to handle concurrent access from pool threads.
        set_tls_measurement_context(g_target_context);
        tls_cached_coverage_map = g_target_context->coverage_map;
        return g_target_context->coverage_map;
    }

    // Get the current task (Swift task or sync pseudo-task)
    void* task = get_current_task_for_measurement();
    bool inheritance_active = (g_coverage_inheritance_key != NULL);

    // Snapshot the liveness epoch up front. The cached resolution below is only
    // trustworthy while inheritance is active if NO begin/end has happened since
    // it was filled (see g_active_ctx_epoch).
    uint64_t resolve_epoch = atomic_load_explicit(&g_active_ctx_epoch, memory_order_acquire);

#if !SANCOV_DISABLE_TLS_CACHE
    // FAST PATH: cached map for this exact task. Avoids the per-edge runtime
    // task-local lookup + liveness lock in the common case.
    //
    // When inheritance is active the cache is trusted ONLY while the epoch is
    // unchanged. An unchanged epoch means no measurement began or ended since we
    // resolved this task, so (a) the cached context is still the correct routing
    // target and (b) it is still alive (held by this thread's
    // tls_cached_measurement_context reference) — so returning its map needs no
    // re-validation and no reference dance. Any begin/end bumps the epoch and
    // forces the full, lock-protected re-resolve below (which closes TOCTOU/ABA).
    if (task == tls_cached_task && tls_cached_task_map != NULL) {
        if (!inheritance_active || resolve_epoch == tls_cached_generation) {
            return tls_cached_task_map;
        }
        // Epoch changed → a begin/end occurred; re-resolve.
        atomic_fetch_add_explicit(&g_route_tls_cache_inheritance_active, 1, memory_order_relaxed);
    }
#endif

    // Task changed - need to do full lookup.
    //
    // ORDER MATTERS: when coverage inheritance is active, check inheritance
    // BEFORE the per-task registry. Reason: Swift's task allocator reuses
    // task memory addresses across tests, and the per-task registry can hold
    // stale mappings from a prior test whose task had this same address.
    // Inheritance walks the live task-local chain, which is always current.
    // When inheritance returns NULL (task not in an inheritance scope) we
    // fall back to the registry — that's the path for synchronous code or
    // engine root tasks that registered themselves explicitly.
    SanCovMeasurementContext* inherited = NULL;
    bool inherited_via_runtime = false;
    if (inheritance_active) {
        // The task-local carries a generation-tagged HANDLE, not a raw pointer.
        uint64_t handle = 0;
        if (g_coverage_inheritance_key != NULL) {
            // Try the runtime's own lookup first (resolved once, race-free).
            pthread_once(&swift_task_localValueLookup_once, resolve_swift_task_localValueLookup);
            if (swift_task_localValueLookup_fn) {
                void* result = swift_task_localValueLookup_fn(g_coverage_inheritance_key);
                if (result) {
                    memcpy(&handle, result, sizeof(handle));
                    if (handle != 0) {
                        inherited_via_runtime = true;
                    }
                }
            }
        }
        // Fallback: walk the task's own chain manually. Also tried when the
        // captured key is unset — manual walk's value-match fallback covers
        // routing solely via the active-context registry.
        if (handle == 0) {
            handle = manual_walk_for_inherited_context(task);
        }
        // Resolve the handle to a LIVE, generation-matched context, retained.
        // A task-local can outlive the measurement it captured — e.g. an
        // unstructured poller task spawned inside a fuzz iteration keeps firing
        // edges after that measurement ended and its context was freed (and the
        // address may since have been recycled by an unrelated measurement).
        // retain_inherited_if_valid (a) rejects an ended context, (b) for a
        // still-live address takes a reference under the liveness lock so it
        // cannot be freed before we dereference it (TOCTOU, review #52), and
        // (c) verifies the generation tag so a recycled address routing to the
        // WRONG live context is rejected (ABA, review #53/#56). On success
        // `inherited` is retained and the path below MUST ctx_release it.
        inherited = retain_inherited_if_valid(handle);
    }
    if (inherited != NULL) {
        // We hold a temporary reference (from retain_if_active above), so these
        // dereferences are safe even if the owning session is ending concurrently.
        if (inherited->coverage_map != NULL) {
            if (inherited_via_runtime) {
                atomic_fetch_add_explicit(&g_route_inherited_runtime, 1, memory_order_relaxed);
            } else {
                atomic_fetch_add_explicit(&g_route_inherited_manualwalk, 1, memory_order_relaxed);
            }
            uint8_t* map = inherited->coverage_map;
            tls_cached_task = task;
            tls_cached_task_map = map;
            tls_cached_generation = resolve_epoch;
            set_tls_measurement_context(inherited);  // takes its own reference
            ctx_release(inherited);                   // drop our temporary reference
            return map;
        }
        // Live but no coverage_map yet: drop the temporary reference and fall
        // through to the per-task registry / TLS fallback.
        ctx_release(inherited);
        inherited = NULL;
    }

    // Fallback: per-task registry (for synchronous code / engine root tasks).
    SanCovMeasurementContext* measurement_ctx = (SanCovMeasurementContext*)get_measurement_context_for_task(task);
    if (measurement_ctx != NULL) {
        atomic_fetch_add_explicit(&g_route_per_task_registry, 1, memory_order_relaxed);
#if !SANCOV_DISABLE_TLS_CACHE
        // Check measurement context cache
        if (measurement_ctx == tls_cached_measurement_context && tls_cached_coverage_map != NULL) {
            // Update task cache to point to measurement map
            tls_cached_task = task;
            tls_cached_task_map = tls_cached_coverage_map;
            tls_cached_generation = resolve_epoch;
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
            tls_cached_generation = resolve_epoch;
            return map;
        }
    }

    // No measurement context - use thread-local storage directly
    // We don't create task-keyed entries in the hash table because they would
    // never be cleaned up (we don't have a hook for task completion).
    // TLS is fine here since coverage outside of measurements isn't isolated anyway.
    if (inheritance_active) {
        atomic_fetch_add_explicit(&g_route_tls_fallback_inheritance_active, 1, memory_order_relaxed);
        // Sub-categorize: was this a synchronous call (no Swift task), a Swift
        // task with empty chain, or a Swift task whose chain didn't match
        // anything? The last is the only category that would indicate a real
        // routing bug — the first two are expected noise from edges firing on
        // non-inheriting work while some inheritance scope happens to be live.
        void* swift_task = NULL;
        if (swift_task_getCurrent != NULL) swift_task = swift_task_getCurrent();
        if (swift_task == NULL) {
            atomic_fetch_add_explicit(&g_route_tlsfb_sync_pseudo_task, 1, memory_order_relaxed);
        } else {
            const void* head = NULL;
            memcpy(&head, (const char*)swift_task + SANCOV_TASK_LOCAL_HEAD_OFFSET, sizeof(head));
            if (head == NULL || !sancov_is_valid_pointer(head)) {
                atomic_fetch_add_explicit(&g_route_tlsfb_real_task_no_head, 1, memory_order_relaxed);
            } else {
                atomic_fetch_add_explicit(&g_route_tlsfb_real_task_no_match, 1, memory_order_relaxed);
            }
        }
    } else {
        atomic_fetch_add_explicit(&g_route_tls_fallback_no_inheritance, 1, memory_order_relaxed);
    }
    ensure_tls_coverage_map();
    tls_cached_task = task;
    tls_cached_task_map = tls_coverage_map;
    tls_cached_generation = resolve_epoch;
    // Clear stale measurement context so sancov_record_edge doesn't append
    // edges from this task into another test's measurement context.
    set_tls_measurement_context(NULL);
    return tls_coverage_map;
}

// Diagnostic: read routing path counters. Tests can use this to verify that
// edges actually went where expected. No log spam — pure atomic loads.
void sancov_read_route_counters(SanCovRouteCounters* out) {
    if (!out) return;
    out->target_ctx = atomic_load_explicit(&g_route_target_ctx, memory_order_relaxed);
    out->tls_cache_inheritance_active = atomic_load_explicit(&g_route_tls_cache_inheritance_active, memory_order_relaxed);
    out->inherited_runtime = atomic_load_explicit(&g_route_inherited_runtime, memory_order_relaxed);
    out->inherited_manualwalk = atomic_load_explicit(&g_route_inherited_manualwalk, memory_order_relaxed);
    out->per_task_registry = atomic_load_explicit(&g_route_per_task_registry, memory_order_relaxed);
    out->tls_fallback_inheritance_active = atomic_load_explicit(&g_route_tls_fallback_inheritance_active, memory_order_relaxed);
    out->tls_fallback_no_inheritance = atomic_load_explicit(&g_route_tls_fallback_no_inheritance, memory_order_relaxed);
    out->tlsfb_sync_pseudo_task = atomic_load_explicit(&g_route_tlsfb_sync_pseudo_task, memory_order_relaxed);
    out->tlsfb_real_task_no_head = atomic_load_explicit(&g_route_tlsfb_real_task_no_head, memory_order_relaxed);
    out->tlsfb_real_task_no_match = atomic_load_explicit(&g_route_tlsfb_real_task_no_match, memory_order_relaxed);
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
        // Atomic first-hit check: only ONE thread transitions 0→1. Concurrent
        // child tasks inheriting the same measurement context may race on this
        // cell; atomic compare-and-swap ensures only the winner proceeds to
        // trie advance / indices append.
        uint8_t expected = 0;
        if (__atomic_compare_exchange_n(&map[*guard], &expected, (uint8_t)1,
                                         false, __ATOMIC_ACQ_REL, __ATOMIC_RELAXED)) {
            SanCovMeasurementContext* ctx = tls_cached_measurement_context;
            if (ctx) {
                // Atomic fetch_add so each concurrent child task gets a
                // unique slot in covered_indices. The buffer is sized to
                // g_guard_count in sancov_begin_measurement so there can
                // be no realloc race here.
                size_t idx = __atomic_fetch_add(&ctx->covered_count, 1, __ATOMIC_RELAXED);
                maybe_advance_trie(ctx, *guard);
                if (idx < ctx->covered_indices_capacity) {
                    ctx->covered_indices[idx] = *guard;
                }
            }
        }
    }
}

__attribute__((noinline))
void sancov_record_edge_counting(uint32_t *guard) {
    uint8_t* map = get_current_coverage_map();
    if (map && *guard < g_guard_count) {
        // Atomic first-hit check so concurrent child tasks (under
        // CoverageInheritance) can't both observe 0 and both record first-hit.
        uint8_t expected = 0;
        if (__atomic_compare_exchange_n(&map[*guard], &expected, (uint8_t)1,
                                         false, __ATOMIC_ACQ_REL, __ATOMIC_RELAXED)) {
            SanCovMeasurementContext* ctx = tls_cached_measurement_context;
            if (ctx) {
                size_t idx = __atomic_fetch_add(&ctx->covered_count, 1, __ATOMIC_RELAXED);
                if (idx < ctx->covered_indices_capacity) {
                    ctx->covered_indices[idx] = *guard;
                }
            }
        } else {
            // Already first-hit. Saturating 8-bit increment for counting mode.
            // Relaxed because exact count per iteration isn't required for
            // bucketing — any count >= 1 means "hit" and saturates at 255.
            uint8_t cur = __atomic_load_n(&map[*guard], __ATOMIC_RELAXED);
            while (cur < 255) {
                if (__atomic_compare_exchange_n(&map[*guard], &cur, (uint8_t)(cur + 1),
                                                 false, __ATOMIC_RELAXED, __ATOMIC_RELAXED)) {
                    break;
                }
            }
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
    // Mutate the cross-pointers under g_trie_lock so a concurrent teardown
    // (sancov_trie_destroy / detach_trie_from_dying_context) observes a
    // consistent link and the two pointers never disagree.
    os_unfair_lock_lock(&g_trie_lock);
    if (context) context->path_trie = trie;
    if (trie) trie->owner_context = context;
    os_unfair_lock_unlock(&g_trie_lock);
}

// Sever the context<->trie link from the CONTEXT side as it is freed. After this
// the trie's owner_context no longer points at the (about-to-be-freed) context,
// so sancov_trie_destroy will not write through a dangling pointer.
static void detach_trie_from_dying_context(SanCovMeasurementContext* ctx) {
    os_unfair_lock_lock(&g_trie_lock);
    SanCovPathTrie* trie = ctx->path_trie;
    if (trie && trie->owner_context == ctx) {
        trie->owner_context = NULL;
    }
    ctx->path_trie = NULL;
    os_unfair_lock_unlock(&g_trie_lock);
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
    // Sever the link from BOTH sides under g_trie_lock before freeing: clear the
    // owner context's forward pointer (so it won't use this freed trie) AND our
    // own back-pointer. Holding the lock keeps this consistent with a concurrent
    // detach_trie_from_dying_context / sancov_context_set_trie. The owner pointer
    // is only dereferenced while linked under the lock, so it is never dangling
    // here (a freed context clears this back-pointer via the detach path).
    os_unfair_lock_lock(&g_trie_lock);
    SanCovMeasurementContext* owner = trie->owner_context;
    if (owner && owner->path_trie == trie) {
        owner->path_trie = NULL;
    }
    trie->owner_context = NULL;
    os_unfair_lock_unlock(&g_trie_lock);

    trie_node_destroy(trie->root);
    free(trie);
}

// TESTING ONLY seams (see SanCovHooks.h).
void sancov_release_for_testing(SanCovMeasurementContext* context) {
    ctx_release(context);
}

SanCovMeasurementContext* sancov_trie_owner_context_for_testing(const SanCovPathTrie* trie) {
    if (!trie) return NULL;
    os_unfair_lock_lock(&g_trie_lock);
    SanCovMeasurementContext* owner = trie->owner_context;
    os_unfair_lock_unlock(&g_trie_lock);
    return owner;
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

// Edge hook function pointer — set by Swift via sancov_install_swift_hook().
// Before Swift init, falls back to sancov_record_edge directly. Atomic because
// parallel fuzzing installs the (same) hook from many engine threads at once
// while the per-edge hot path reads it concurrently (TSan-confirmed write/read
// race under `fuzz(parallelism:)` × N concurrent calls).
// Stored as atomic pointer-sized bits (the __atomic builtins reject a
// function-pointer _Atomic directly); cast on store/load. Function-pointer ↔
// uintptr_t round-trips losslessly on every supported target (same assumption
// dlsym relies on).
typedef void (*EdgeHookFn)(uint32_t*);
// Plain (not _Atomic-qualified): accessed via the __atomic_* builtins, which
// provide atomic load/store on plain types — matching how g_edge_state and the
// map cells are handled elsewhere in this file.
static uintptr_t g_edge_hook_bits = 0;

void sancov_install_swift_hook(void (*hook)(uint32_t*)) {
    __atomic_store_n(&g_edge_hook_bits, (uintptr_t)hook, __ATOMIC_RELEASE);
}

// Forward declarations for lazy edge filter (defined later in file alongside
// the upfront filter helpers). State pointer and state byte values are
// declared here so the hot path can reference them.
#define EDGE_STATE_UNCHECKED 0
#define EDGE_STATE_ALLOWED   1
#define EDGE_STATE_SKIP      2
extern uint8_t* g_edge_state;
static void check_and_cache_edge_lazy(uint32_t* guard, uint32_t g);

void __sanitizer_cov_trace_pc_guard(uint32_t *guard) {
    // Fast-path: out-of-range or upfront-cached-SKIP guards (set to
    // SANCOV_GUARD_SKIP once, under pthread_once, before any edge fires) skip.
    // `*guard` is never written after that init barrier, so this read is
    // race-free under parallel fuzzing.
    uint32_t g = *guard;
    if (g >= g_guard_count) return;

    // Lazy filter: classify on first fire of each edge, then cache the verdict
    // in g_edge_state (atomic). The classification — NOT a `*guard` stamp — is
    // the single source of truth, so concurrent engines firing the same edge do
    // not race on the shared guard global (TSan-confirmed fix).
    if (__builtin_expect(g_edge_state != NULL, 1)) {
        uint8_t state = __atomic_load_n(&g_edge_state[g], __ATOMIC_ACQUIRE);
        if (__builtin_expect(state == EDGE_STATE_UNCHECKED, 0)) {
            check_and_cache_edge_lazy(guard, g);
            // Re-read the cached verdict: SKIP → suppress.
            if (__atomic_load_n(&g_edge_state[g], __ATOMIC_ACQUIRE) == EDGE_STATE_SKIP) return;
        } else if (state == EDGE_STATE_SKIP) {
            return;
        }
    }

    EdgeHookFn hook = (EdgeHookFn)__atomic_load_n(&g_edge_hook_bits, __ATOMIC_ACQUIRE);
    if (hook) {
        hook(guard);
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

// MARK: - Lazy Edge Filter + Disk Cache
//
// Replaces the upfront `dladdr` scan with a per-edge first-fire check, results
// of which are persisted to disk and re-applied on subsequent process runs of
// the same binary. After warm-up, both first-fire and subsequent fires of any
// known edge cost ~1 byte load + 1 branch.
//
// Edge state values defined above next to the hot path (forward decls).

uint8_t* g_edge_state = NULL;                   // size = g_guard_count when allocated
static size_t   g_lazy_filtered_count = 0;
static size_t   g_lazy_allowed_count = 0;
static int      g_edge_state_dirty = 0;         // atomic flag: persist on exit
static pthread_once_t g_filter_init_once = PTHREAD_ONCE_INIT;

#define SANCOV_FILTER_CACHE_MAGIC ((uint64_t)0x5345434f56523031ULL) // "SECOVR01"

static void compute_cache_path(char* out, size_t out_size) {
    out[0] = '\0';
    if (!g_guards_start) return;
    Dl_info info;
    if (!dladdr((void*)g_guards_start, &info) || !info.dli_fname) return;
    struct stat st;
    if (stat(info.dli_fname, &st) != 0) return;

    const char* tmp = getenv("TMPDIR");
    if (!tmp || tmp[0] == '\0') tmp = "/tmp";

    // Stable per-binary key: inode + mtime. Survives rebuilds via mtime.
    // Path: $TMPDIR/sancov-filter-<inode>-<mtime>.bin
    snprintf(out, out_size, "%ssancov-filter-%llu-%lld.bin",
             tmp, (unsigned long long)st.st_ino,
             (long long)st.st_mtimespec.tv_sec);
}

static void load_filter_cache(void) {
    char path[1024];
    compute_cache_path(path, sizeof(path));
    if (path[0] == '\0') return;

    int fd = open(path, O_RDONLY);
    if (fd < 0) return;

    uint64_t header[2];
    ssize_t n = read(fd, header, sizeof(header));
    if (n != (ssize_t)sizeof(header) ||
        header[0] != SANCOV_FILTER_CACHE_MAGIC ||
        header[1] != (uint64_t)g_guard_count) {
        close(fd);
        return;
    }
    n = read(fd, g_edge_state, g_guard_count);
    close(fd);
    if (n != (ssize_t)g_guard_count) {
        // Partial read: best-effort, treat unread bytes as UNCHECKED.
        memset(g_edge_state + (n > 0 ? n : 0), EDGE_STATE_UNCHECKED,
               g_guard_count - (n > 0 ? n : 0));
        return;
    }

    // Apply cached SKIP markers to guards eagerly so the existing
    // `*guard < g_guard_count` hot-path gate short-circuits without reading
    // g_edge_state at all.
    size_t loaded_skip = 0, loaded_allowed = 0;
    for (size_t i = 0; i < g_guard_count; i++) {
        if (g_edge_state[i] == EDGE_STATE_SKIP) {
            g_guards_start[i] = SANCOV_GUARD_SKIP;
            loaded_skip++;
        } else if (g_edge_state[i] == EDGE_STATE_ALLOWED) {
            loaded_allowed++;
        }
    }
    g_lazy_filtered_count = loaded_skip;
    g_lazy_allowed_count = loaded_allowed;
}

static void save_filter_cache(void) {
    if (!__atomic_load_n(&g_edge_state_dirty, __ATOMIC_ACQUIRE)) return;
    if (!g_edge_state || g_guard_count == 0) return;

    char path[1024];
    compute_cache_path(path, sizeof(path));
    if (path[0] == '\0') return;

    char tmp_path[1100];
    snprintf(tmp_path, sizeof(tmp_path), "%s.tmp.%d", path, (int)getpid());

    int fd = open(tmp_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return;

    uint64_t header[2] = { SANCOV_FILTER_CACHE_MAGIC, (uint64_t)g_guard_count };
    if (write(fd, header, sizeof(header)) != (ssize_t)sizeof(header)) {
        close(fd); unlink(tmp_path); return;
    }
    if (write(fd, g_edge_state, g_guard_count) != (ssize_t)g_guard_count) {
        close(fd); unlink(tmp_path); return;
    }
    close(fd);
    rename(tmp_path, path); // atomic on POSIX
}

static void filter_init_impl(void) {
    if (g_guard_count == 0) return;
    g_edge_state = (uint8_t*)calloc(g_guard_count, 1);
    if (!g_edge_state) return;
    load_filter_cache();
    atexit(save_filter_cache);
}

static inline void ensure_filter_init(void) {
    pthread_once(&g_filter_init_once, filter_init_impl);
}

// Slow path: classify a single edge on its first fire and update state.
// Called rarely (once per edge, ever). Sets either:
//   - state[g] = SKIP     (compiler-generated noise; never stamps *guard)
//   - state[g] = ALLOWED  (real instrumented code)
// Forward-declared up near the hot path.
static void check_and_cache_edge_lazy_impl(uint32_t* guard, uint32_t g);
static void check_and_cache_edge_lazy(uint32_t* guard, uint32_t g) {
    check_and_cache_edge_lazy_impl(guard, g);
}
static void check_and_cache_edge_lazy_impl(uint32_t* guard, uint32_t g) {
    if (!g_edge_state) return;

    bool is_noise = false;
    // Need PCs to dladdr. If pcs aren't available (e.g., multi-module without
    // the pcs_init fix), default to ALLOWED — graceful degradation.
    if (g_pcs_start && g < g_pcs_count) {
        uintptr_t pc = g_pcs_start[(size_t)g * 2];
        if (pc != 0) {
            Dl_info info;
            if (dladdr((void*)pc, &info) && info.dli_sname) {
                is_noise = sancov_is_compiler_generated(info.dli_sname);
            }
        }
    }

    if (is_noise) {
        // Record the verdict in g_edge_state only. Do NOT stamp `*guard` — that
        // shared global is read lock-free on the hot path by every concurrent
        // engine, so writing it here is a data race (TSan-confirmed). The atomic
        // g_edge_state verdict already suppresses future fires.
        __atomic_store_n(&g_edge_state[g], (uint8_t)EDGE_STATE_SKIP, __ATOMIC_RELEASE);
        __atomic_fetch_add(&g_lazy_filtered_count, 1, __ATOMIC_RELAXED);
    } else {
        __atomic_store_n(&g_edge_state[g], (uint8_t)EDGE_STATE_ALLOWED, __ATOMIC_RELEASE);
        __atomic_fetch_add(&g_lazy_allowed_count, 1, __ATOMIC_RELAXED);
    }
    __atomic_store_n(&g_edge_state_dirty, 1, __ATOMIC_RELEASE);
}

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
    // Filtering is now lazy + cached. Allocate the state array, load the
    // on-disk cache (if present), and apply any cached SKIP markers eagerly.
    // After this, individual edges are classified at their first fire.
    ensure_filter_init();
    g_filter_applied = true;
}

size_t sancov_get_filtered_count(void) {
    // Backwards-compatible: report the running tally from the lazy filter,
    // plus any leftover from old upfront passes (now zero in practice).
    size_t lazy = __atomic_load_n(&g_lazy_filtered_count, __ATOMIC_RELAXED);
    return lazy + g_filtered_count;
}
