# Investigation: Worker Pool Heap Corruption

## Symptom
- Heap corruption crashes when running full test suite
- Crash manifests in Swift runtime metadata cache during JSON encoding
- Does NOT crash when running tests in isolation
- Likely root cause test: `testFuzzEngineWithCustomType`

## Key Change
FuzzStateMachine refactor: from **one task per input** to **worker pool where same task runs many inputs**.

User insight: "The underlying infrastructure expects single input/test per task"

## What Has NOT Changed
- SanCov TLS code (unchanged since tests were passing)
- The possibility of task hopping between threads during a measurement

## TLS Cache Analysis - REVISITED

**Old model (one task per input)**:
- Task T1 runs input 1, caches on Thread A, hops to B, endMeasurement frees map
- Thread A has stale cache for T1
- But T1 is DONE - it never runs again
- Stale cache only matters if NEW task T2 gets same address as T1 (rare)

**New model (worker pool)**:
- Task T1 runs iteration 1, caches on Thread A, hops to B, endMeasurement frees map
- Thread A has stale cache for T1
- Task T1 runs iteration 2: beginMeasurement on Thread B creates new map
- During iteration 2, task T1 hops BACK to Thread A
- Thread A: task T1 == tls_cached_task, returns FREED map!

**Key insight**: The difference isn't whether thread-hopping was possible.
The difference is whether the SAME TASK POINTER is used multiple times.
- Old model: Requires task address reuse (rare, dependent on allocator)
- New model: Same task guaranteed to run multiple times (common, by design)

**TEST RESULT**: Disabled TLS cache (SANCOV_DISABLE_TLS_CACHE=1), crash STILL happens!
This means TLS cache staleness is NOT the root cause.

## Other Possibilities

### Potential race in coverage map lifetime
1. Thread A: Task T1 gets measurement context C, gets map M
2. Thread A: About to write to map M
3. Thread B: Task T1's endMeasurement runs (task hopped to B)
4. Thread B: cleanup_task_map frees map M
5. Thread A: Writes to freed map M -> CRASH

But can this happen? Swift tasks only run on one thread at a time. The task would
have to be suspended on Thread A while endMeasurement runs on Thread B. If the task
is suspended, trace_pc_guard shouldn't be called...

Unless: signals/interrupts, or trace_pc_guard is called during stack unwinding?

### Memory allocator issues
- Could be a heap corruption manifesting later during JSON encoding
- The corruption source could be entirely outside of SanCov

### Need to determine EXACT crash location
- Run with lldb to catch the crash
- Get full backtrace at crash time
- Check if crash is in trace_pc_guard, JSON encoding, or elsewhere

## Test Isolation Results

1. `CustomMutatorProvidingTests` (includes `testFuzzEngineWithCustomType`) - PASSES in isolation
2. `FuzzEngineTests` - Has separate issue: `try!` in catch block crashes when mock throws error
3. Full suite - SIGBUS crash (signal 10)

The crash only happens with full suite, suggesting:
- Memory corruption from one test affects another test
- Or some cumulative state builds up across tests

## Code Fixes Applied
1. Fixed `try!` in catch block (FuzzStateMachine.swift:96) - changed to `try?` with fallback
   - This fixed a separate crash (`MockCoverageUnavailableError`) but SIGBUS still occurs
2. Added SANCOV_DISABLE_TLS_CACHE flag for testing TLS cache hypothesis
   - Disabling TLS cache did NOT fix SIGBUS crash

## Current Status
- SIGBUS (signal 10) still occurs intermittently when running full test suite
- Tests pass in isolation (`CustomMutatorProvidingTests` passes)
- TLS cache staleness is NOT the root cause (verified by disabling cache)
- The crash happens at different points in the test suite (intermittent)

## Still To Investigate

### 1. Measurement context association with tasks
- `sancov_begin_measurement` associates context with task via `set_measurement_context_for_task`
- `sancov_end_measurement` removes the association
- What happens if same task calls beginMeasurement while still having an active context? (shouldn't happen with current code, but worth verifying)

### 2. Coverage map hash table (g_coverage_ht)
- Maps measurement context pointer → coverage map
- `find_or_create_task_map(ctx)` uses ctx as key
- `cleanup_task_map(ctx)` removes and frees
- Any race conditions with concurrent workers?

### 3. Measurement context hash table (g_measurement_ht)
- Maps task pointer → measurement context
- Multiple workers = multiple tasks, each with own entry
- But what if task pointer gets reused after task completion?

### 4. ck_ht concurrent operations - INVESTIGATED
- "SPMC" API but has additional synchronization for resize
- Writers call `ck_ht_wait_for_resize()` to spin-wait during resize
- Resize is mutex-protected, sets `resize_in_progress` flag
- Individual writes use atomic operations, no mutex between writers
- **Key insight**: Each worker task has a unique task pointer as key
  - Old model: Many concurrent tasks (one per test)
  - New model: Fewer concurrent tasks (number of workers)
  - Hash table contention should actually be LOWER in new model
- **Coverage map keying**: Maps are keyed by measurement context pointer, not task pointer
  - `find_or_create_task_map(ctx)` uses ctx (measurement context) as key
  - Each measurement context gets its own map
- **No obvious race**: Same task executes sequentially (iteration N+1 starts after iteration N ends)

### 5. Non-SanCov shared state
- `CorpusCoder.corpusEncoder` / `corpusDecoder` - static JSONEncoder/JSONDecoder
- `SourceLocationCache.shared` - actor, should be safe
- `_dwarfSymbolizerHelper` / `_functionSizeLookup` - nonisolated(unsafe) but lock-protected
- Swift Testing's issue handling - does `withKnownIssue` have task-scoped state?

### 6. Dependency injection context
- swift-dependencies uses task-local storage
- Workers inherit parent's dependency context
- Dependencies resolved once in `setupWorkerPool`, not per-iteration

### 7. The test closure itself
```swift
test: { testInput in
    await self.haltIfAtLimit(startTime: self.startTime)
    let context = coverageCountersClient.beginMeasurement()
    // ... test execution ...
    coverageCountersClient.endMeasurement(context)
}
```
- `self` is FuzzStateMachine actor - multiple workers calling actor methods
- `coverageCountersClient` captured once, shared across workers
- Any state in the captured closures?

## ROOT CAUSE FOUND (LLDB Debugging Session 2026-01-12)

### Stack Trace at Crash
```
* frame #0: libsystem_malloc.dylib`_xzm_xzone_malloc_freelist_outlined + 864
  frame #1: xmalloc(size=16) at SanCovHooks.c:37
  frame #2: sancov_begin_measurement at SanCovHooks.c:266
  frame #3: static SanCovCounters.beginMeasurement() at SanCovCounters.swift:371
  frame #4: closure #1 in FuzzStateMachine.setupWorkerPool at FuzzStateMachine.swift:81
```

### The Bug: Use-After-Free in `__sanitizer_cov_trace_pc_guard`

```c
void __sanitizer_cov_trace_pc_guard(uint32_t *guard) {
    uint8_t* map = get_current_coverage_map();
    if (map && *guard < g_guard_count) {
        if (map[*guard] == 0) {
            map[*guard] = 1;
            if (tls_cached_measurement_context) {
                tls_cached_measurement_context->covered_count++;  // <-- USE-AFTER-FREE!
            }
        }
    }
}
```

### Why This Happens with Worker Pool

1. **Thread X**: Worker Task W starts iteration 1
   - `begin_measurement` creates ctx_1
   - Coverage hooks fire, `tls_cached_measurement_context = ctx_1` on Thread X

2. **Thread Y**: Worker Task W hops threads for async work
   - Task continues on Thread Y

3. **Thread Y**: Worker Task W ends iteration 1
   - `end_measurement` frees ctx_1
   - Only clears TLS on Thread Y: `if (tls_cached_measurement_context == ctx) clear`
   - **Thread X's TLS still has stale pointer to freed ctx_1!**

4. **Thread Z**: Worker Task W starts iteration 2
   - `begin_measurement` creates ctx_2

5. **Thread X**: Different task or same task hops back
   - Coverage hook fires on Thread X
   - `tls_cached_measurement_context` still points to **FREED ctx_1**
   - Writes `ctx_1->covered_count++` → **USE-AFTER-FREE**
   - Corrupts malloc's freelist metadata

6. **Later**: Any allocation triggers malloc to traverse corrupted freelist → **CRASH**

### Why SANCOV_DISABLE_TLS_CACHE Didn't Fix It

The `SANCOV_DISABLE_TLS_CACHE` flag only affects the task_map lookup in `get_current_coverage_map()`:
```c
#if !SANCOV_DISABLE_TLS_CACHE
    // FAST PATH: Check if we have a cached map for this exact task
    if (task == tls_cached_task && tls_cached_task_map != NULL) {
        return tls_cached_task_map;
    }
#endif
```

It does NOT affect the `tls_cached_measurement_context->covered_count++` in `__sanitizer_cov_trace_pc_guard`.
The use-after-free happens regardless of the cache flag.

### The Fix

Option A: Re-validate before incrementing
```c
if (tls_cached_measurement_context) {
    // Verify the cached context is still valid for current task
    void* task = get_current_task_for_measurement();
    SanCovMeasurementContext* actual_ctx = get_measurement_context_for_task(task);
    if (tls_cached_measurement_context == actual_ctx) {
        tls_cached_measurement_context->covered_count++;
    }
}
```

Option B: Don't increment covered_count in trace_pc_guard at all
- Increment is just an optimization to avoid counting later
- Instead, count non-zero entries in the map when needed

Option C: Track covered_count atomically in a separate location
- Not tied to the measurement context struct
- Keyed by task/context in a way that's safe across threads

## Fix Applied and Verified

**Fix**: Option 2 - Atomic reference counting on measurement contexts.

Changes:
1. Added `_Atomic int refcount` field to `SanCovMeasurementContext` struct
2. Added `ctx_retain()` and `ctx_release()` helper functions
3. Added `set_tls_measurement_context()` helper that properly retains/releases when updating TLS cache
4. `sancov_begin_measurement()` initializes refcount to 1 (owner reference)
5. `sancov_end_measurement()` releases owner reference; context freed when refcount hits 0
6. TLS cache updates use `set_tls_measurement_context()` to maintain refcounts
7. Added `sancov_create_dummy_context()` for Swift test code (Swift can't initialize atomic fields directly)

**Verification**:
- Without fix: WorkerPoolPatternTests fail ~30% of the time (3/10 runs failed)
- With fix: WorkerPoolPatternTests pass 30/30 runs (100%)

**Benefits**:
1. Preserves the incremental `covered_count++` optimization on the hot path
2. Measurement contexts stay alive as long as any TLS cache holds a reference
3. No scanning overhead - count is maintained incrementally as before
4. Thread-safe via atomic operations

## Separate Issue Found

During full test suite runs, found a separate bug: infinite recursion in `FuzzStateMachine.captureIssues` at line 178. The `matching:` closure calls `Issue.record()` which triggers the issue handling chain again, causing stack overflow. This is unrelated to the SanCov heap corruption.
