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

// MARK: - Coalesced thread-local state (one TLS block per thread)
//
// PERFORMANCE: every distinct `_Thread_local` variable accessed in a dylib
// lowers to a `tlv_get_addr` *function call* on macOS. The per-comparison hot
// path (sancov_dispatch_cmp → get_current_coverage_map) touched ~6 separate
// thread-locals, so it paid ~6 tlv_get_addr calls per instrumented comparison —
// profiled at ~30% of the cmp-dispatch subtree (Finding 41c). Coalescing them
// into ONE struct lets the hot path fetch the block address ONCE (a single
// tlv_get_addr) and read/write every field as a struct offset. The address is
// resolved at each hot entry point and threaded down through `ts` so no callee
// re-fetches it.
//
// Field-by-field provenance (was N separate `_Thread_local` globals):
typedef struct SanCovTLS {
    // Schedule-aware target context (ScheduleControl). When non-NULL ALL edges
    // route here regardless of task/thread. Set in sancov_set_target_context.
    SanCovMeasurementContext* target_context;
    // Non-async fallback coverage map (lazily calloc'd by ensure_tls_coverage_map).
    uint8_t* coverage_map;
    // Pseudo-task id for synchronous code outside any async context.
    void* sync_pseudo_task;
    // Hot-path cache: last resolved (task → map) pair and the liveness epoch it
    // was resolved under. See get_current_coverage_map's fast path.
    void* cached_task;
    uint8_t* cached_task_map;
    SanCovMeasurementContext* cached_measurement_context;  // refcounted (see set_tls_measurement_context)
    uint8_t* cached_coverage_map;
    uint64_t cached_generation;
    // Re-entry guard: set while inside a cmp recorder / reset hook so a
    // comparison fired by the recorder cannot re-dispatch and recurse
    // (CmpRecorderTests stack-overflow; the cmp twin of in_edge_observer).
    bool in_cmp_recorder;
    // Re-entry guard: set while inside an edge observer callback so edges fired
    // BY the callback never re-enter it (non-reentrant-lock deadlock).
    bool in_edge_observer;
    // Generation guard: set by the fuzz loop around input generation/mutation,
    // which executes instrumented SUT code (e.g. a type-directed generator
    // calling getTyp) whose edges/comparisons are NOT the property under test —
    // they are reset away before the test runs, so dispatching+recording them is
    // pure waste (~25% of the process; scheduler-lab Finding 41p). When set, the
    // dispatch hooks early-return on this thread. Per-thread so concurrent engines
    // (one mutating, one testing) don't suppress each other.
    bool suppressed;
} SanCovTLS;

static _Thread_local SanCovTLS g_tls = {0};

// One tlv_get_addr; callees take the returned pointer as `ts` and never re-fetch.
// always_inline so the hot dispatch paths fold the TLS fetch in-line (no call
// frame, and the compiler keeps the resolved base in a register).
__attribute__((always_inline))
static inline SanCovTLS* sancov_tls(void) { return &g_tls; }

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
static void set_tls_measurement_context(SanCovTLS* ts, SanCovMeasurementContext* new_ctx);

// (Thread-local fallback map now lives in SanCovTLS.coverage_map.)

// Measurement registry: task_id -> measurement_context
static ck_ht_t g_measurement_ht;
static pthread_once_t g_measurement_ht_once = PTHREAD_ONCE_INIT;
static pthread_rwlock_t g_measurement_ht_lock = PTHREAD_RWLOCK_INITIALIZER;

// (Pseudo-task id now lives in SanCovTLS.sync_pseudo_task.)

// Global generation counter - incremented when any measurement context ends.
// Used to invalidate stale TLS caches across all threads.
static _Atomic uint64_t g_measurement_generation = 0;

// (Hot-path cache fields — cached_task / cached_task_map /
// cached_measurement_context / cached_coverage_map / cached_generation — now
// live in SanCovTLS. The cache is invalidated when task changes or a
// measurement context ends.)

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

// Dispatch counters (env-gated PTK_DISPATCH_COUNT): count the edge vs cmp
// dispatches that actually pay the per-thread TLS fetch (post-filter, post-
// suppress) so we can see which channel dominates tlv_get_addr. Relaxed atomics
// — only the RATIO matters, so the cross-core contention they add to the
// counting run is irrelevant. `cmp_recorded` counts the kept cmp dispatches that
// reached an attached recorder; (cmp - cmp_recorded) is TLS paid with no
// consumer (edge-only strategies still fire the trace-cmp hooks). Dumped to
// stderr at exit. Off ⇒ one predicted-not-taken load on the hot path.
static bool g_dispatch_count_on = false;
static _Atomic uint64_t g_dispatch_edge_count = 0;
static _Atomic uint64_t g_dispatch_cmp_count = 0;
static _Atomic uint64_t g_dispatch_cmp_recorded = 0;

// Process-global count of measurement contexts with a cmp recorder attached.
// sancov_dispatch_cmp early-returns before the TLS fetch when this is 0, so
// edge-only strategies (no cmp consumer) don't pay cmp-routing for comparisons
// nobody reads (Finding 42: ~33M unconsumed cmp TLS fetches / 6s). Adjusted only
// at recorder attach/detach (measurement setup/teardown), never on the hot path.
static _Atomic int g_cmp_recorder_count = 0;

// Apply a cmp_recorder_bits transition to the global count: 0→nonzero attaches
// (+1), nonzero→0 detaches (-1), nonzero→nonzero (re-attach) is a no-op.
static inline void cmp_recorder_count_adjust(uintptr_t old_bits, uintptr_t new_bits) {
    if (old_bits == 0 && new_bits != 0) {
        atomic_fetch_add_explicit(&g_cmp_recorder_count, 1, memory_order_acq_rel);
    } else if (old_bits != 0 && new_bits == 0) {
        atomic_fetch_sub_explicit(&g_cmp_recorder_count, 1, memory_order_acq_rel);
    }
}

int sancov_cmp_recorder_count_for_testing(void) {
    return atomic_load_explicit(&g_cmp_recorder_count, memory_order_acquire);
}

// Get or create a pseudo-task ID for synchronous code
static void* get_sync_pseudo_task(SanCovTLS* ts) {
    if (ts->sync_pseudo_task == NULL) {
        // Use a unique heap address as pseudo-task ID
        ts->sync_pseudo_task = xmalloc(1);
    }
    return ts->sync_pseudo_task;
}

// Get the current task (Swift task or sync pseudo-task)
static void* get_current_task_for_measurement(SanCovTLS* ts) {
    if (swift_task_getCurrent != NULL) {
        void* task = swift_task_getCurrent();
        if (task != NULL) {
            return task;
        }
    }
    return get_sync_pseudo_task(ts);
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
    remove_measurement_context_for_task(get_current_task_for_measurement(sancov_tls()));
}

// TESTING ONLY (see header): drop just the current task's measurement-registry
// entry; leave the active-inheritance set and the context allocation untouched.
// Bumps the liveness epoch so every thread's hot-path cache is invalidated —
// otherwise the owning thread's cached map pointer would keep routing the
// owning task's edges into the context after the registry entry is gone.
void sancov_remove_task_measurement_for_testing(void) {
    SanCovTLS* ts = sancov_tls();
    remove_measurement_context_for_task(get_current_task_for_measurement(ts));
    // Clear this thread's hot-path cache so a stale cached map pointer can't keep
    // routing the owning task's edges into the (now-deregistered) context. The
    // epoch bump covers inheritance-active readers; clearing the TLS cache also
    // covers the !inheritance_active fast-path short-circuit (which ignores the
    // epoch). Mirrors the cache teardown in sancov_end_measurement.
    set_tls_measurement_context(ts, NULL);
    ts->cached_task = NULL;
    ts->cached_task_map = NULL;
    ts->cached_coverage_map = NULL;
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

// Defined below with the recorder API; ONE release path so a future fix to
// the data-release semantics cannot land in one copy and miss the other.
static void release_recorder_data(SanCovMeasurementContext* context);
static void release_cmp_recorder_data(SanCovMeasurementContext* context);

// Release a measurement context (decrement refcount, free if zero)
static void ctx_release(SanCovMeasurementContext* ctx) {
    if (ctx) {
        int old_count = atomic_fetch_sub(&ctx->refcount, 1);
        if (old_count == 1) {
            // Refcount dropped to zero, free the context. Drop the co-owned
            // recorder data now: the fn was severed at end_measurement, and
            // with the last reference gone no thread can still dispatch into
            // this context, so releasing the data here can race nothing.
            release_recorder_data(ctx);
            release_cmp_recorder_data(ctx);
            cleanup_task_map(ctx);
            free(ctx->covered_indices);
            free(ctx);
        }
    }
}

// Helper to update TLS cached measurement context with proper refcounting
static void set_tls_measurement_context(SanCovTLS* ts, SanCovMeasurementContext* new_ctx) {
    SanCovMeasurementContext* old_ctx = ts->cached_measurement_context;
    if (old_ctx != new_ctx) {
        ctx_retain(new_ctx);  // Retain new (NULL is safe)
        ts->cached_measurement_context = new_ctx;
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

// xmalloc does not zero: every freshly allocated context must start with the
// recorder fields cleared (default recorder, no data, no lifecycle hooks).
static void init_recorder_fields(SanCovMeasurementContext* ctx) {
    ctx->edge_recorder_bits = 0;
    ctx->recorder_data = NULL;
    ctx->recorder_reset_bits = 0;
    ctx->recorder_release_bits = 0;
    ctx->cmp_recorder_bits = 0;
    ctx->cmp_recorder_data = NULL;
    ctx->cmp_recorder_reset_bits = 0;
    ctx->cmp_recorder_release_bits = 0;
}

SanCovMeasurementContext* sancov_begin_measurement(void) {
    SanCovMeasurementContext* ctx = (SanCovMeasurementContext*)xmalloc(sizeof(SanCovMeasurementContext));
    ctx->coverage_map = NULL;
    atomic_init(&ctx->covered_count, 0);
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
    init_recorder_fields(ctx);
    atomic_init(&ctx->refcount, 1);  // Start with refcount of 1 (owner reference)

    // Associate this measurement context with the current task
    SanCovTLS* ts = sancov_tls();
    void* task = get_current_task_for_measurement(ts);
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
            set_tls_measurement_context(ts, ctx);
            ts->cached_coverage_map = map;
            ts->cached_task = task;
            ts->cached_task_map = map;
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
    atomic_init(&ctx->covered_count, 0);
    ctx->generation = (uint16_t)atomic_fetch_add_explicit(&g_next_generation, 1, memory_order_relaxed);
    ctx->covered_indices_capacity = 0;
    ctx->covered_indices = NULL;
    init_recorder_fields(ctx);
    atomic_init(&ctx->refcount, 1);
    return ctx;
}

// (The in-cmp-recorder re-entry guard now lives in SanCovTLS.in_cmp_recorder.)
// A cmp recorder's OWN body — and any reset hook — contains instrumented
// comparisons whenever it is compiled into a trace-cmp module; each such
// comparison fires __sanitizer_cov_trace_cmp* -> sancov_dispatch_cmp, which
// would re-enter the recorder and recurse without bound (observed as a 500-deep
// stack overflow / SIGBUS in CmpRecorderTests, whose recorders live in the
// trace-cmp-instrumented test target). This is the cmp twin of
// in_edge_observer: while set, sancov_dispatch_cmp is a no-op so a recorder can
// never re-dispatch into itself.

/// Reset coverage for a measurement context (cheap memset, O(1) for covered_count).
/// Used between iterations in the fuzz loop to avoid hash table insert/remove overhead.
void sancov_reset_coverage(SanCovMeasurementContext* ctx) {
    if (ctx == NULL) return;
    SanCovTLS* ts = sancov_tls();

    if (ctx->coverage_map != NULL && g_guard_count > 0) {
        memset(ctx->coverage_map, 0, g_guard_count);
    }
    atomic_store_explicit(&ctx->covered_count, 0, memory_order_relaxed);
    // covered_indices buffer is reused — just reset the count (capacity stays)

    // Clear the calling thread's TLS-cached coverage map pointer so the next
    // edge that fires on this thread re-routes through get_current_coverage_map.
    ts->cached_coverage_map = NULL;
    // We deliberately do NOT memset whatever bitmap `cached_task_map` points
    // at. Under parallel test execution that pointer can target another active
    // test's coverage_map (a worker thread previously executed a child task
    // whose routing populated the cache, then was reassigned to this iteration
    // before any edge fired to refresh the cache). Wiping it silently dropped
    // coverage in foreign concurrent measurements (parallelEngineIsolation).

    // Reset per-iteration recorder state (e.g. a path-trie cursor back to
    // root) through the generic hook, so strategy state replays from a clean
    // slate each iteration just like the coverage map does.
    SanCovRecorderDataFn reset =
        (SanCovRecorderDataFn)__atomic_load_n(&ctx->recorder_reset_bits, __ATOMIC_ACQUIRE);
    if (reset) {
        reset(__atomic_load_n(&ctx->recorder_data, __ATOMIC_ACQUIRE));
    }

    // Same per-iteration reset for the independent cmp recorder (e.g. clear the
    // value-profile feature set so each iteration starts from a clean slate).
    // Guard with in_cmp_recorder: a trace-cmp-instrumented reset hook fires
    // comparisons of its own, which must not re-dispatch into the (still
    // attached) cmp recorder and recurse.
    SanCovRecorderDataFn cmp_reset =
        (SanCovRecorderDataFn)__atomic_load_n(&ctx->cmp_recorder_reset_bits, __ATOMIC_ACQUIRE);
    if (cmp_reset) {
        ts->in_cmp_recorder = true;
        cmp_reset(__atomic_load_n(&ctx->cmp_recorder_data, __ATOMIC_ACQUIRE));
        ts->in_cmp_recorder = false;
    }

}

// Release the context's current recorder data through its release hook (if
// any), consuming both fields. Callers must have already cleared the recorder
// fn so no new dispatch can reach the data being released.
//
// Atomic exchanges, not load-then-store: two concurrent releasers would each
// load the same (release, data) pair and double-invoke the hook. With
// exchanges each field is taken exactly once, so at most one caller can hold
// both — a race degrades to a leak, never a double release. (In-tree callers
// never race; this closes the latent header-contract violation for free.)
static void release_recorder_data(SanCovMeasurementContext* context) {
    SanCovRecorderDataFn release =
        (SanCovRecorderDataFn)__atomic_exchange_n(&context->recorder_release_bits, 0, __ATOMIC_ACQ_REL);
    void* data = __atomic_exchange_n(&context->recorder_data, NULL, __ATOMIC_ACQ_REL);
    if (release && data) {
        release(data);
    }
}

// The cmp-recorder twin of release_recorder_data — same exchange-not-load
// reasoning (a race degrades to a leak, never a double release).
static void release_cmp_recorder_data(SanCovMeasurementContext* context) {
    SanCovRecorderDataFn release =
        (SanCovRecorderDataFn)__atomic_exchange_n(&context->cmp_recorder_release_bits, 0, __ATOMIC_ACQ_REL);
    void* data = __atomic_exchange_n(&context->cmp_recorder_data, NULL, __ATOMIC_ACQ_REL);
    if (release && data) {
        release(data);
    }
}

void sancov_context_set_recorder(
    SanCovMeasurementContext* context,
    SanCovEdgeRecorder recorder,
    void* data,
    SanCovRecorderDataFn reset,
    SanCovRecorderDataFn release) {
    if (context == NULL) return;

    // Stop new dispatch/reset against the OLD state, then drop ownership of it.
    // (Replacing while edges actively dispatch is unsupported; see header.)
    __atomic_store_n(&context->edge_recorder_bits, 0, __ATOMIC_RELEASE);
    __atomic_store_n(&context->recorder_reset_bits, 0, __ATOMIC_RELEASE);
    release_recorder_data(context);

    if (recorder) {
        // Data and hooks first, then the fn (release): a dispatcher that
        // observes the fn (acquire) is guaranteed to observe what it needs.
        __atomic_store_n(&context->recorder_release_bits, (uintptr_t)release, __ATOMIC_RELEASE);
        __atomic_store_n(&context->recorder_data, data, __ATOMIC_RELEASE);
        __atomic_store_n(&context->recorder_reset_bits, (uintptr_t)reset, __ATOMIC_RELEASE);
        __atomic_store_n(&context->edge_recorder_bits, (uintptr_t)recorder, __ATOMIC_RELEASE);
    } else if (release && data) {
        // Clearing while passing a payload: ownership still transferred, so
        // honor the header's "release is called exactly once" instead of
        // silently dropping it.
        release(data);
    }
}

// The cmp-recorder twin of sancov_context_set_recorder — same ordering and
// ownership contract, applied to the independent cmp slot.
void sancov_context_set_cmp_recorder(
    SanCovMeasurementContext* context,
    SanCovCmpRecorder recorder,
    void* data,
    SanCovRecorderDataFn reset,
    SanCovRecorderDataFn release) {
    if (context == NULL) return;

    // Capture the prior recorder so the global cmp-recorder count tracks the
    // 0↔nonzero transition (gates sancov_dispatch_cmp — see g_cmp_recorder_count).
    uintptr_t old_cmp = __atomic_exchange_n(&context->cmp_recorder_bits, 0, __ATOMIC_RELEASE);
    __atomic_store_n(&context->cmp_recorder_reset_bits, 0, __ATOMIC_RELEASE);
    release_cmp_recorder_data(context);

    if (recorder) {
        __atomic_store_n(&context->cmp_recorder_release_bits, (uintptr_t)release, __ATOMIC_RELEASE);
        __atomic_store_n(&context->cmp_recorder_data, data, __ATOMIC_RELEASE);
        __atomic_store_n(&context->cmp_recorder_reset_bits, (uintptr_t)reset, __ATOMIC_RELEASE);
        __atomic_store_n(&context->cmp_recorder_bits, (uintptr_t)recorder, __ATOMIC_RELEASE);
    } else if (release && data) {
        // Clear-with-payload: ownership still transferred, release once.
        release(data);
    }
    cmp_recorder_count_adjust(old_cmp, recorder ? (uintptr_t)recorder : 0);
}

// sancov_context_get_recorder_data lives in the header as static inline (hot path).

// TESTING ONLY seams (see SanCovHooks.h).
void* sancov_context_get_recorder_for_testing(SanCovMeasurementContext* context) {
    if (context == NULL) return NULL;
    return (void*)__atomic_load_n(&context->edge_recorder_bits, __ATOMIC_ACQUIRE);
}

void* sancov_context_get_cmp_recorder_for_testing(SanCovMeasurementContext* context) {
    if (context == NULL) return NULL;
    return (void*)__atomic_load_n(&context->cmp_recorder_bits, __ATOMIC_ACQUIRE);
}

void sancov_release_for_testing(SanCovMeasurementContext* context) {
    ctx_release(context);
}

void sancov_retain_for_testing(SanCovMeasurementContext* context) {
    ctx_retain(context);
}

/// Cleanup caches, etc
void sancov_end_measurement(SanCovMeasurementContext* ctx) {
    if (ctx == NULL) return;

    // Sever the recorder fn FIRST: stragglers that retain this context past
    // `end` must dispatch to the default recorder. The recorder DATA (and its
    // release hook) deliberately stay: a straggler that loaded the fn just
    // before this store may still read the data, and every thread that can
    // dispatch holds a context reference via its TLS cache — so the data is
    // released only when the last reference drops (see ctx_release). That
    // closes the in-flight use-after-free window the old "attacher keeps the
    // data alive" contract merely documented.
    __atomic_store_n(&ctx->edge_recorder_bits, 0, __ATOMIC_RELEASE);
    __atomic_store_n(&ctx->recorder_reset_bits, 0, __ATOMIC_RELEASE);
    // Sever the cmp recorder on the same terms (data survives for stragglers).
    uintptr_t old_cmp = __atomic_exchange_n(&ctx->cmp_recorder_bits, 0, __ATOMIC_RELEASE);
    cmp_recorder_count_adjust(old_cmp, 0);
    __atomic_store_n(&ctx->cmp_recorder_reset_bits, 0, __ATOMIC_RELEASE);

    // Drop the inheritance registration first so concurrent routing decisions
    // stop matching this context by value pointer before we tear it down.
    unregister_active_inheritance_context(ctx);

    // Remove the measurement context from the current task
    SanCovTLS* ts = sancov_tls();
    void* task = get_current_task_for_measurement(ts);
    remove_measurement_context_for_task(task);

    // Invalidate this thread's TLS cache if it matches
    // Note: Other threads may still hold TLS references - that's OK because
    // the refcount will keep the context alive until they release it.
    if (ts->cached_measurement_context == ctx) {
        set_tls_measurement_context(ts, NULL);  // Releases our TLS reference
        ts->cached_coverage_map = NULL;
    }
    ts->cached_task = NULL;
    ts->cached_task_map = NULL;

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
    // covered_count is bumped on edge-firing threads (record_first_hit), so a
    // plain read here is a data race (TSan-confirmed). The field is _Atomic.
    return atomic_load_explicit(&ctx->covered_count, memory_order_relaxed);
}

// Allocate and fill an array of covered edge indices.
//
const uint32_t* sancov_get_covered_indices(SanCovMeasurementContext* ctx, size_t* out_count) {
    if (!ctx || !out_count) {
        if (out_count) *out_count = 0;
        return NULL;
    }
    size_t count = atomic_load_explicit(&ctx->covered_count, memory_order_relaxed);
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

    size_t count = atomic_load_explicit(&ctx->covered_count, memory_order_relaxed);
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

// Ensure thread-local fallback map is allocated
static void ensure_tls_coverage_map(SanCovTLS* ts) {
    if (ts->coverage_map == NULL && g_guard_count > 0) {
        ts->coverage_map = (uint8_t*)calloc(g_guard_count, 1);
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

// Resolves routing using the caller's already-fetched TLS block (`ts`), so the
// per-edge / per-comparison hot path pays a single tlv_get_addr at its entry and
// every field touch here is a struct offset. Behaviour is identical to the old
// per-variable form; only the storage was coalesced (Finding 41c).
static uint8_t* get_current_coverage_map(SanCovTLS* ts) {
    // HIGHEST PRIORITY: schedule-aware target context.
    // When schedule fuzzing is active, ALL edge hits go to the engine's context
    // regardless of which task/thread they fire on.
    if (ts->target_context != NULL) {
        atomic_fetch_add_explicit(&g_route_target_ctx, 1, memory_order_relaxed);
        // Route all edges to the target context. Set cached_measurement_context
        // so the attached recorder/observer and covered_indices are maintained
        // (observer state guards its own concurrent access from pool threads).
        set_tls_measurement_context(ts, ts->target_context);
        ts->cached_coverage_map = ts->target_context->coverage_map;
        return ts->target_context->coverage_map;
    }

    // Get the current task (Swift task or sync pseudo-task)
    void* task = get_current_task_for_measurement(ts);
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
    // cached_measurement_context reference) — so returning its map needs no
    // re-validation and no reference dance. Any begin/end bumps the epoch and
    // forces the full, lock-protected re-resolve below (which closes TOCTOU/ABA).
    if (task == ts->cached_task && ts->cached_task_map != NULL) {
        if (!inheritance_active || resolve_epoch == ts->cached_generation) {
            return ts->cached_task_map;
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
            ts->cached_task = task;
            ts->cached_task_map = map;
            ts->cached_generation = resolve_epoch;
            set_tls_measurement_context(ts, inherited);  // takes its own reference
            ctx_release(inherited);                       // drop our temporary reference
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
        if (measurement_ctx == ts->cached_measurement_context && ts->cached_coverage_map != NULL) {
            // Update task cache to point to measurement map
            ts->cached_task = task;
            ts->cached_task_map = ts->cached_coverage_map;
            ts->cached_generation = resolve_epoch;
            return ts->cached_coverage_map;
        }
#endif
        // Slow path: lookup or create, then cache
        uint8_t* map = find_or_create_task_map(measurement_ctx);
        if (map != NULL) {
            set_tls_measurement_context(ts, measurement_ctx);  // Properly retain/release
            ts->cached_coverage_map = map;
            ts->cached_task = task;
            ts->cached_task_map = map;
            ts->cached_generation = resolve_epoch;
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
    ensure_tls_coverage_map(ts);
    ts->cached_task = task;
    ts->cached_task_map = ts->coverage_map;
    ts->cached_generation = resolve_epoch;
    // Clear stale measurement context so dispatched edges don't append
    // edges from this task into another test's measurement context.
    set_tls_measurement_context(ts, NULL);
    return ts->coverage_map;
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

// MARK: - Edge Recorders
//
// Recorders receive the guard plus the already-resolved (map, ctx) so the hot
// path never runs routing twice. ctx may be NULL (no-measurement TLS fallback).

/// Atomic first-hit: only ONE thread transitions a map cell 0→1. Concurrent
/// child tasks inheriting the same measurement context may race on the cell;
/// compare-and-swap ensures only the winner appends to covered_indices.
/// The indices append uses atomic fetch_add so each concurrent child task gets
/// a unique slot; the buffer is sized to g_guard_count in
/// sancov_begin_measurement so there can be no realloc race here.
/// Returns true on the first hit.
static inline bool record_first_hit(uint32_t edge, uint8_t* map, SanCovMeasurementContext* ctx) {
    uint8_t expected = 0;
    if (!__atomic_compare_exchange_n(&map[edge], &expected, (uint8_t)1,
                                     false, __ATOMIC_ACQ_REL, __ATOMIC_RELAXED)) {
        return false;
    }
    if (ctx) {
        size_t idx = atomic_fetch_add_explicit(&ctx->covered_count, 1, memory_order_relaxed);
        if (idx < ctx->covered_indices_capacity) {
            ctx->covered_indices[idx] = edge;
        }
    }
    return true;
}

void sancov_recorder_default(uint32_t* guard, uint8_t* map, SanCovMeasurementContext* ctx) {
    if (map && *guard < g_guard_count) {
        record_first_hit(*guard, map, ctx);
    }
}

SanCovEdgeRecording sancov_record_edge_first_hit(uint32_t* guard, uint8_t* map, SanCovMeasurementContext* ctx) {
    if (!guard || !map || *guard >= g_guard_count) return SANCOV_EDGE_SKIPPED;
    return record_first_hit(*guard, map, ctx) ? SANCOV_EDGE_FIRST_HIT : SANCOV_EDGE_REPEAT;
}

// (The in-edge-observer re-entry guard now lives in SanCovTLS.in_edge_observer:
// set while the calling thread is inside an observer callback, so edges fired BY
// the callback never re-enter it — re-entry deadlocks any non-reentrant lock the
// callback holds.)

bool sancov_observer_enter(void) {
    SanCovTLS* ts = sancov_tls();
    if (ts->in_edge_observer) return false;
    ts->in_edge_observer = true;
    return true;
}

void sancov_observer_exit(void) {
    sancov_tls()->in_edge_observer = false;
}

// MARK: - Schedule-Aware Target Context

void sancov_set_target_context(SanCovMeasurementContext* context) {
    SanCovTLS* ts = sancov_tls();
    ts->target_context = context;
    // The target interlude rebinds cached_measurement_context to the target
    // while leaving the per-task fast path's (task, map) pairing intact. A
    // post-interlude dispatch would then take the fast path and pair the task's
    // own map with the target's still-cached context — silently appending
    // covered indices (and firing the recorder/observer) on the wrong engine.
    // Dropping the task cache forces the next dispatch through the full resolve,
    // which re-pairs map and context together.
    ts->cached_task = NULL;
    ts->cached_task_map = NULL;
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
    atomic_store_explicit(&ctx->covered_count, count, memory_order_relaxed);
}

// Per-edge dispatch: resolve routing once, then run the context's recorder.
// There is NO process-global hook — the recorder choice lives on the
// measurement context (edge_recorder_bits), so concurrent tests/engines with
// different strategies never stomp each other. ctx->edge_recorder_bits is read
// with the __atomic builtins (a fn-ptr _Atomic is rejected; cast on load —
// fn-ptr ↔ uintptr_t round-trips losslessly on every supported target, the
// same assumption dlsym relies on).
// Process-global "ever-covered" edge bitmap (diagnostic). See the API block
// near the bottom of this file. Default NULL ⇒ recording disabled ⇒ the hot
// path below pays one predicted-not-taken atomic load. Once enabled, every
// allowed edge fire sets a byte to 1; nothing in the fuzz loop ever clears it
// (only sancov_reset_global_ever_covered). Writes are idempotent stores of the
// constant 1 — concurrent engines writing the same value to the same byte is a
// benign race (the only transition is 0→1, no torn value for a single byte).
static _Atomic(uint8_t*) g_ever_covered = NULL;

void sancov_dispatch_edge(uint32_t *guard) {
    uint8_t* ever = atomic_load_explicit(&g_ever_covered, memory_order_acquire);
    if (__builtin_expect(ever != NULL, 0)) {
        uint32_t ge = *guard;
        if (ge < g_guard_count) ever[ge] = 1;  // idempotent; see note above
    }
    SanCovTLS* ts = sancov_tls();  // one tlv_get_addr for the whole dispatch
    // Generation guard: skip routing+recording for edges fired by input
    // generation/mutation (not the property under test). See SanCovTLS.suppressed.
    if (ts->suppressed) return;
    if (__builtin_expect(g_dispatch_count_on, 0))
        atomic_fetch_add_explicit(&g_dispatch_edge_count, 1, memory_order_relaxed);
    uint8_t* map = get_current_coverage_map(ts);
    SanCovMeasurementContext* ctx = ts->cached_measurement_context;
    if (ctx) {
        SanCovEdgeRecorder r = (SanCovEdgeRecorder)__atomic_load_n(&ctx->edge_recorder_bits, __ATOMIC_ACQUIRE);
        if (r) {
            r(guard, map, ctx);
            return;
        }
    }
    sancov_recorder_default(guard, map, ctx);
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

    sancov_dispatch_edge(guard);
}

// MARK: - Comparison Census (diagnostic, env-gated: PTK_CMP_CENSUS=<path>)
//
// Answers "is comparison VOLUME concentrated in a few sites, and do the hot
// sites approach the boundary?" — i.e. is there a filterable population, or is
// the volume the relevant SUT-logic comparisons themselves (scheduler-lab
// Finding 41f follow-up). Records per comparison-site PC: fire count and the
// minimum |arg1-arg2| ever seen. Symbol resolution (dladdr) is deferred to the
// atexit dump, so the per-comparison cost is one CAS-claim + two relaxed RMWs on
// a fixed open-addressing table — and ZERO when disabled (one predicted-not-taken
// atomic load of g_cmp_census, same pattern as g_ever_covered). Enabled once at
// load via the constructor below; never touches production unless the env is set.
typedef struct {
    _Atomic uint64_t pc;        // 0 = empty slot
    _Atomic uint64_t count;     // fire volume
    _Atomic uint64_t min_dist;  // min |arg1-arg2|, starts UINT64_MAX
} CmpCensusEntry;

typedef struct {
    CmpCensusEntry* slots;
    size_t capacity;            // power of two
    const char* path;
} CmpCensus;

static CmpCensus* _Atomic g_cmp_census = NULL;

static inline uint64_t cmp_census_hash(uint64_t x) {
    x += 0x9E3779B97F4A7C15ULL;
    x = (x ^ (x >> 30)) * 0xBF58476D1CE4E5B9ULL;
    x = (x ^ (x >> 27)) * 0x94D049BB133111EBULL;
    return x ^ (x >> 31);
}

static void cmp_census_record(uint64_t pc, uint64_t arg1, uint64_t arg2) {
    CmpCensus* c = atomic_load_explicit(&g_cmp_census, memory_order_acquire);
    if (__builtin_expect(c == NULL, 1)) return;
    uint64_t dist = arg1 > arg2 ? arg1 - arg2 : arg2 - arg1;
    size_t m = c->capacity - 1;
    size_t i = (size_t)(cmp_census_hash(pc) & (uint64_t)m);
    for (size_t probes = 0; probes <= m; probes++) {
        CmpCensusEntry* e = &c->slots[i];
        uint64_t k = atomic_load_explicit(&e->pc, memory_order_relaxed);
        if (k == 0) {
            uint64_t expected = 0;
            if (!atomic_compare_exchange_strong_explicit(
                    &e->pc, &expected, pc, memory_order_acq_rel, memory_order_relaxed)
                && expected != pc) {
                i = (i + 1) & m;  // lost claim to a different pc; keep probing
                continue;
            }
            // won the claim, or another thread claimed it for THIS pc — fall through
            k = pc;
        }
        if (k == pc) {
            atomic_fetch_add_explicit(&e->count, 1, memory_order_relaxed);
            uint64_t cur = atomic_load_explicit(&e->min_dist, memory_order_relaxed);
            while (dist < cur) {
                if (atomic_compare_exchange_weak_explicit(
                        &e->min_dist, &cur, dist, memory_order_relaxed, memory_order_relaxed))
                    break;
            }
            return;
        }
        i = (i + 1) & m;
    }
    // table full: drop (census is best-effort)
}

static void cmp_census_dump(void) {
    CmpCensus* c = atomic_load_explicit(&g_cmp_census, memory_order_acquire);
    if (c == NULL) return;
    FILE* f = fopen(c->path, "w");
    if (f == NULL) return;
    fprintf(f, "# count\tmin_dist\tpc\tsymbol\n");
    for (size_t i = 0; i < c->capacity; i++) {
        uint64_t pc = atomic_load_explicit(&c->slots[i].pc, memory_order_relaxed);
        if (pc == 0) continue;
        uint64_t count = atomic_load_explicit(&c->slots[i].count, memory_order_relaxed);
        uint64_t md = atomic_load_explicit(&c->slots[i].min_dist, memory_order_relaxed);
        const char* sym = "?";
        Dl_info info;
        if (dladdr((void*)(uintptr_t)pc, &info) && info.dli_sname) sym = info.dli_sname;
        fprintf(f, "%llu\t%llu\t0x%llx\t%s\n",
                (unsigned long long)count,
                (unsigned long long)(md == UINT64_MAX ? 0 : md),
                (unsigned long long)pc, sym);
    }
    fclose(f);
}

__attribute__((constructor))
static void cmp_census_init(void) {
    const char* path = getenv("PTK_CMP_CENSUS");
    if (path == NULL || path[0] == '\0') return;
    CmpCensus* c = (CmpCensus*)xmalloc(sizeof(CmpCensus));
    c->capacity = 16384;  // power of two; ≫ any workload's distinct cmp-site count
    c->slots = (CmpCensusEntry*)calloc(c->capacity, sizeof(CmpCensusEntry));
    if (c->slots == NULL) { free(c); return; }
    for (size_t i = 0; i < c->capacity; i++) {
        atomic_init(&c->slots[i].min_dist, UINT64_MAX);
    }
    c->path = path;
    atomic_store_explicit(&g_cmp_census, c, memory_order_release);
    atexit(cmp_census_dump);
}

static void dispatch_count_dump(void) {
    if (!g_dispatch_count_on) return;
    unsigned long long e = atomic_load_explicit(&g_dispatch_edge_count, memory_order_relaxed);
    unsigned long long c = atomic_load_explicit(&g_dispatch_cmp_count, memory_order_relaxed);
    unsigned long long cr = atomic_load_explicit(&g_dispatch_cmp_recorded, memory_order_relaxed);
    fprintf(stderr,
        "=== PTK_DISPATCH_COUNT ===\n"
        "edge_dispatches  %llu\n"
        "cmp_dispatches   %llu\n"
        "cmp_recorded     %llu   (cmp - recorded = %llu paid TLS with no consumer)\n",
        e, c, cr, (c >= cr ? c - cr : 0));
}

__attribute__((constructor))
static void dispatch_count_init(void) {
    const char* v = getenv("PTK_DISPATCH_COUNT");
    if (v == NULL || v[0] == '\0' || v[0] == '0') return;
    g_dispatch_count_on = true;
    atexit(dispatch_count_dump);
}

// MARK: - Comparison Drop Filter (env-gated: PTK_CMP_DROP_SYNTHESIZED)
//
// Per comparison-site PC verdict cache: on a PC's first fire, dladdr resolves
// its enclosing function and sancov_cmp_should_drop classifies the mangled name;
// the verdict (KEEP/DROP) is cached so every later fire is an O(1) table lookup.
// Lock-free open-addressing, same structure/sizing as the census. Default
// disabled (g_cmp_drop_table NULL → one predicted-not-taken acquire load per
// comparison, then the normal dispatch).
typedef struct {
    _Atomic uint64_t pc;       // 0 = empty slot
    _Atomic uint8_t verdict;   // 0 = unknown, 1 = keep, 2 = drop
} CmpDropEntry;

typedef struct {
    CmpDropEntry* slots;
    size_t capacity;           // power of two
} CmpDropTable;

static CmpDropTable* _Atomic g_cmp_drop_table = NULL;

uint64_t sancov_cmp_dropped_count(void) {
    // Number of DISTINCT comparison sites being dropped (verdict == drop). An
    // on-demand slot scan — no per-comparison counting, so the hot path stays
    // pure (two relaxed loads + early return). Per-site volume is the census's
    // job; this just confirms the filter classified some sites as droppable.
    CmpDropTable* t = atomic_load_explicit(&g_cmp_drop_table, memory_order_acquire);
    if (t == NULL) return 0;
    uint64_t sites = 0;
    for (size_t i = 0; i < t->capacity; i++) {
        if (atomic_load_explicit(&t->slots[i].verdict, memory_order_relaxed) == 2) {
            sites++;
        }
    }
    return sites;
}

// Returns true if the comparison at `pc` should be skipped. Resolves+caches the
// verdict on first fire. Caller guarantees the filter is enabled (table != NULL).
// The settled-entry hot path is two relaxed loads + a compare — no atomic RMW,
// so dropping costs essentially nothing beyond the routing it avoids.
static bool cmp_drop_should_skip(CmpDropTable* t, uintptr_t pc) {
    size_t m = t->capacity - 1;
    size_t i = (size_t)(cmp_census_hash((uint64_t)pc) & (uint64_t)m);
    for (size_t probes = 0; probes <= m; probes++) {
        CmpDropEntry* e = &t->slots[i];
        uint64_t k = atomic_load_explicit(&e->pc, memory_order_relaxed);
        if (k == 0) {
            uint64_t expected = 0;
            if (!atomic_compare_exchange_strong_explicit(
                    &e->pc, &expected, (uint64_t)pc,
                    memory_order_acq_rel, memory_order_relaxed)
                && expected != (uint64_t)pc) {
                i = (i + 1) & m;  // lost claim to a different pc; keep probing
                continue;
            }
            k = (uint64_t)pc;  // won the claim, or it was already ours
        }
        if (k == (uint64_t)pc) {
            uint8_t v = atomic_load_explicit(&e->verdict, memory_order_acquire);
            if (v == 0) {
                // First fire for this PC: classify and cache. Idempotent under
                // races (every thread computes the same verdict for one PC).
                Dl_info info;
                bool drop = (dladdr((void*)pc, &info) && info.dli_sname)
                            ? sancov_cmp_should_drop(info.dli_sname) : false;
                v = drop ? 2 : 1;
                atomic_store_explicit(&e->verdict, v, memory_order_release);
            }
            return v == 2;
        }
        i = (i + 1) & m;
    }
    return false;  // table full: keep (filter is best-effort)
}

__attribute__((constructor))
static void cmp_drop_init(void) {
    // Default ON: synthesized/stdlib comparison sites carry no SUT signal and
    // taxing them only slows the trace-cmp strategies (measured +1.57× throughput
    // when dropped). Opt OUT with PTK_CMP_DROP_SYNTHESIZED=0 — e.g. when a bug can
    // manifest as a value at a stdlib bounds-check comparison.
    const char* v = getenv("PTK_CMP_DROP_SYNTHESIZED");
    if (v != NULL && (v[0] == '0' || v[0] == '\0')) return;
    CmpDropTable* t = (CmpDropTable*)xmalloc(sizeof(CmpDropTable));
    t->capacity = 16384;  // power of two; ≫ any workload's distinct cmp-site count
    t->slots = (CmpDropEntry*)calloc(t->capacity, sizeof(CmpDropEntry));
    if (t->slots == NULL) { free(t); return; }
    atomic_store_explicit(&g_cmp_drop_table, t, memory_order_release);
}

// MARK: - Comparison Dispatch (trace-cmp / value profile)

// Per-comparison dispatch: resolve routing once (same current-context lookup as
// sancov_dispatch_edge — get_current_coverage_map populates the TLS context as
// a side effect), then run the context's cmp recorder if one is attached. No
// edge map is touched; cmp recording is a parallel channel. No-op when no cmp
// recorder is attached or no measurement is active.
// Generation guard control (see SanCovTLS.suppressed). Set true around input
// generation/mutation so this thread's instrumented SUT calls aren't dispatched
// or recorded; set false before the property runs. Per-thread; cheap (the bool
// lives in the already-fetched TLS struct).
void sancov_set_dispatch_suppressed(bool suppressed) {
    sancov_tls()->suppressed = suppressed;
}

bool sancov_dispatch_is_suppressed(void) {
    return sancov_tls()->suppressed;
}

void sancov_dispatch_cmp(uintptr_t pc, uint64_t arg1, uint64_t arg2, uint32_t size_bytes) {
    // Drop synthesized/stdlib comparison sites FIRST — before the TLS fetch
    // (default on; opt out with PTK_CMP_DROP_SYNTHESIZED=0). The drop check needs
    // only `pc` (an argument) and the global table (a plain atomic load), NOT the
    // thread-local block, so dropped comparisons never pay the tlv_get_addr that
    // dominates the profile (~21% — Finding 41i). It runs no instrumented
    // comparisons of its own (SanCovHooks/libc are not trace-cmp instrumented),
    // so it is safe ahead of the re-entry guard: a dropped site never reaches the
    // recorder, and kept sites still hit the guard below.
    CmpDropTable* drop = atomic_load_explicit(&g_cmp_drop_table, memory_order_acquire);
    if (__builtin_expect(drop != NULL, 1) && cmp_drop_should_skip(drop, pc)) return;
    // No consumer anywhere → skip the TLS fetch entirely. Edge-only strategies
    // (newEdge / hitCountBuckets / pathTrie / signatureMatch) attach no cmp
    // recorder, so every kept comparison would otherwise pay sancov_tls() +
    // get_current_coverage_map() for nothing (~33M/6s — Finding 42). Both reads
    // are plain global loads (no TLS). The census exemption keeps PTK_CMP_CENSUS
    // working when it is enabled without a recorder. In a MIXED run (some engine
    // has a recorder) the count is >0, so this never suppresses a real consumer.
    if (atomic_load_explicit(&g_cmp_recorder_count, memory_order_acquire) == 0 &&
        atomic_load_explicit(&g_cmp_census, memory_order_acquire) == NULL) return;
    // Fetch this thread's TLS block ONCE (single tlv_get_addr) for the kept sites.
    SanCovTLS* ts = sancov_tls();
    // Re-entry guard (see SanCovTLS.in_cmp_recorder): a comparison fired by the
    // recorder itself (or by a reset hook we are invoking) must NOT re-dispatch,
    // or the recorder recurses into itself and overflows the stack.
    if (ts->in_cmp_recorder) return;
    // Generation guard: skip census + routing + recording for comparisons fired
    // by input generation/mutation (not the property under test). Kept comparisons
    // (SUT funcs like getTyp the mutator calls to validate mutants) reach here;
    // dropped ones already returned at the drop check above. See SanCovTLS.suppressed.
    if (ts->suppressed) return;
    if (__builtin_expect(g_dispatch_count_on, 0))
        atomic_fetch_add_explicit(&g_dispatch_cmp_count, 1, memory_order_relaxed);
    // Diagnostic census (env-gated; one predicted-not-taken load when disabled).
    // Placed after the re-entry guard so it counts only genuine SUT comparisons,
    // not the recorder's own internal ones.
    cmp_census_record(pc, arg1, arg2);
    // Resolve the calling thread's current measurement context. We don't need
    // the returned map, but the call refreshes cached_measurement_context.
    (void)get_current_coverage_map(ts);
    SanCovMeasurementContext* ctx = ts->cached_measurement_context;
    if (!ctx) return;
    SanCovCmpRecorder r = (SanCovCmpRecorder)__atomic_load_n(&ctx->cmp_recorder_bits, __ATOMIC_ACQUIRE);
    if (r) {
        if (__builtin_expect(g_dispatch_count_on, 0))
            atomic_fetch_add_explicit(&g_dispatch_cmp_recorded, 1, memory_order_relaxed);
        ts->in_cmp_recorder = true;
        r(pc, arg1, arg2, size_bytes, ctx);
        ts->in_cmp_recorder = false;
    }
}

// SanitizerCoverage comparison hooks. The compiler emits a call to one of these
// before each instrumented integer comparison / switch, passing the operands.
// We capture the call site via __builtin_return_address(0) as the comparison's
// PC (stable per comparison site) and forward to sancov_dispatch_cmp. const_cmp
// variants (one operand a compile-time constant) route identically — the
// recorder decides whether to treat constants specially.
//
// These run on EVERY comparison in instrumented code (including Swift runtime
// internals: refcounts, bounds checks, address compares), so the recorder MUST
// key by PC to isolate the comparisons it cares about from runtime chatter.
void __sanitizer_cov_trace_cmp1(uint8_t arg1, uint8_t arg2) {
    sancov_dispatch_cmp((uintptr_t)__builtin_return_address(0), arg1, arg2, 1);
}
void __sanitizer_cov_trace_cmp2(uint16_t arg1, uint16_t arg2) {
    sancov_dispatch_cmp((uintptr_t)__builtin_return_address(0), arg1, arg2, 2);
}
void __sanitizer_cov_trace_cmp4(uint32_t arg1, uint32_t arg2) {
    sancov_dispatch_cmp((uintptr_t)__builtin_return_address(0), arg1, arg2, 4);
}
void __sanitizer_cov_trace_cmp8(uint64_t arg1, uint64_t arg2) {
    sancov_dispatch_cmp((uintptr_t)__builtin_return_address(0), arg1, arg2, 8);
}
void __sanitizer_cov_trace_const_cmp1(uint8_t arg1, uint8_t arg2) {
    sancov_dispatch_cmp((uintptr_t)__builtin_return_address(0), arg1, arg2, 1);
}
void __sanitizer_cov_trace_const_cmp2(uint16_t arg1, uint16_t arg2) {
    sancov_dispatch_cmp((uintptr_t)__builtin_return_address(0), arg1, arg2, 2);
}
void __sanitizer_cov_trace_const_cmp4(uint32_t arg1, uint32_t arg2) {
    sancov_dispatch_cmp((uintptr_t)__builtin_return_address(0), arg1, arg2, 4);
}
void __sanitizer_cov_trace_const_cmp8(uint64_t arg1, uint64_t arg2) {
    sancov_dispatch_cmp((uintptr_t)__builtin_return_address(0), arg1, arg2, 8);
}

// switch: cases[0] = number of case constants, cases[1] = value bit width,
// cases[2..] = the case constants (ascending). Emit one comparison per case
// (val vs constant) so the value profile sees how close val came to each arm —
// the switch analog of the cmp gradient.
void __sanitizer_cov_trace_switch(uint64_t val, uint64_t *cases) {
    if (cases == NULL) return;
    uint64_t n = cases[0];
    uint32_t size_bytes = (uint32_t)(cases[1] / 8);
    if (size_bytes == 0) size_bytes = 8;
    uintptr_t pc = (uintptr_t)__builtin_return_address(0);
    for (uint64_t i = 0; i < n; i++) {
        sancov_dispatch_cmp(pc, val, cases[2 + i], size_bytes);
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

// MARK: - Process-global "ever-covered" edge bitmap (diagnostic)
//
// (Storage `g_ever_covered` and the hot-path write live with
// sancov_dispatch_edge above.) This accumulator is the answer to "did a fuzz
// run reach full SUT coverage?" without the confounds that make the per-task
// context and the corpus unsuitable: the context is reset every iteration and
// the corpus only banks ADMITTED inputs, so neither holds the true union of
// edges executed across a whole run. The global bitmap does — it is set on
// every allowed edge fire and only cleared by sancov_reset_global_ever_covered.
//
// All four entry points are intended for a single-threaded diagnostic harness
// between runs; the per-edge write is the only thing that runs under the
// parallel fuzz loop.

void sancov_enable_global_ever_covered(void) {
    if (g_guard_count == 0) return;
    if (atomic_load_explicit(&g_ever_covered, memory_order_acquire) != NULL) return;
    uint8_t* buf = (uint8_t*)calloc(g_guard_count, 1);
    if (!buf) return;
    uint8_t* expected = NULL;
    // CAS so a racing second enable doesn't leak a buffer; first writer wins.
    if (!atomic_compare_exchange_strong_explicit(&g_ever_covered, &expected, buf,
            memory_order_acq_rel, memory_order_acquire)) {
        free(buf);
    }
}

void sancov_reset_global_ever_covered(void) {
    uint8_t* buf = atomic_load_explicit(&g_ever_covered, memory_order_acquire);
    if (buf && g_guard_count > 0) memset(buf, 0, g_guard_count);
}

size_t sancov_global_ever_covered_count(void) {
    uint8_t* buf = atomic_load_explicit(&g_ever_covered, memory_order_acquire);
    if (!buf) return 0;
    size_t n = 0;
    for (size_t i = 0; i < g_guard_count; i++) {
        if (buf[i]) n++;
    }
    return n;
}

uint32_t* sancov_snapshot_global_ever_covered(size_t* out_count) {
    if (out_count) *out_count = 0;
    uint8_t* buf = atomic_load_explicit(&g_ever_covered, memory_order_acquire);
    if (!buf || g_guard_count == 0) return NULL;
    size_t n = 0;
    for (size_t i = 0; i < g_guard_count; i++) {
        if (buf[i]) n++;
    }
    if (n == 0) return NULL;
    uint32_t* out = (uint32_t*)xmalloc(n * sizeof(uint32_t));
    size_t k = 0;
    for (size_t i = 0; i < g_guard_count && k < n; i++) {
        if (buf[i]) out[k++] = (uint32_t)i;
    }
    if (out_count) *out_count = k;
    return out;
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

bool sancov_cmp_should_drop(const char* sname) {
    if (!sname) return false;

    // Everything the edge filter already treats as compiler-generated:
    // outlined ops (WO*), lazy witness/metadata accessors, thunks, addressors.
    // Catches e.g. "...ExprOSgWOe" (outlined consume of STLC.Expr?).
    if (sancov_is_compiler_generated(sname)) return true;

    // Synthesized Equatable conformance (e.g. STLC.Typo.__derived_enum_equals).
    if (strstr(sname, "__derived_enum_equals") != NULL) return true;

    // Standard-library methods. After the Swift symbol prefix ($s / _$s), a
    // digit begins a user-module length prefix (the instrumented SUT, e.g.
    // "4STLC..."); 's' begins the explicit Swift module and 'S' begins a
    // standard-library substitution (Sa=Array, SS=String, SD=Dictionary, ...).
    // So an entity whose first char is 's' or 'S' is a stdlib type's method —
    // bounds checks, count getters, buffer copies — which carry no SUT signal.
    const char* p = sname;
    if (p[0] == '_') p++;
    if (p[0] == '$' && (p[1] == 's' || p[1] == 'S')) {
        p += 2;
        if (*p == 's' || *p == 'S') return true;
    }

    // Value witnesses on a user nominal type: <O|V|C> + 'w' + two lowercase op
    // chars at the very end (e.g. "...ExprOwst" = storeEnumTagSinglePayload).
    // Low volume but synthesized; the trailing form does not collide with the
    // SUT-logic fixtures (none end in w<xx>).
    size_t len = strlen(sname);
    if (len >= 4) {
        const char* e = sname + len;
        if (e[-3] == 'w' &&
            e[-2] >= 'a' && e[-2] <= 'z' &&
            e[-1] >= 'a' && e[-1] <= 'z' &&
            (e[-4] == 'O' || e[-4] == 'V' || e[-4] == 'C')) {
            return true;
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
