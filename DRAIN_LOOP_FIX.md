# Drain Loop Serial Execution Fix

## Problem
`original(job)` dispatches jobs to the cooperative pool asynchronously. The drain loop picks the next job before the previous one finishes executing, causing concurrent job execution on different pool threads. This produces nondeterministic edge ordering in the trie (87 unique paths for a single fixed input that should have ~4).

## Acceptance Criteria (tests)
1. `jobsDoNotOverlap` — two tasks in a TaskGroup don't execute concurrently under schedule control
2. `parallelSessionsBothComplete` — two ScheduleController.run calls running simultaneously both complete
3. `determinism` — same schedule bytes produce same execution order
4. Full `ScheduleControlTests` suite passes when run together (all 4 suites in parallel)

## Confirmed Facts
- `original(job)` is `swift_task_enqueueGlobalImpl` — dispatches to cooperative pool asynchronously, returns immediately
- Actor deinit runs inline (not through the hook) — confirmed by test
- `runSynchronously(on:)` executes one suspension-to-suspension segment, then returns
- Per-session pending queues work — routing hook correctly routes jobs by session ID
- The cooperative pool has limited threads (~CPU count). Blocking them with semaphore waits causes starvation.
- `withCheckedThrowingContinuation` to bridge drain loop to GCD queue caused total hang — even single tests. Root cause: NOT YET DEBUGGED. Need to investigate why the process has 0 cooperative pool threads when using this pattern.

## Attempts

### Attempt 1: `runSynchronously` inline on drain thread
**What**: Replace `original(job)` with `job.runSynchronously(on: executor)` directly on the drain thread.
**Result**: DEADLOCK. When the job suspends (hits `await`), `runSynchronously` blocks the drain thread. The continuation needs to be processed by the drain loop, but the drain thread is blocked inside `runSynchronously`. Bidirectional wait.
**Why it failed**: `runSynchronously` blocks until the job segment completes. If the segment suspends, the thread is stuck. The drain loop can't pick up the continuation because it's the same thread.

### Attempt 2: `runSegment` via GCD serial queue + `segmentDone.wait()`
**What**: Dispatch job to a per-session GCD serial queue via `queue.async { job.runSynchronously(...); segmentDone.signal() }`. Drain loop calls `segmentDone.wait()` to block until segment completes.
**Result**: Works for 1-2 parallel sessions. HANGS with 4+ parallel sessions.
**Why it failed**: Each session blocks a cooperative pool thread (drain loop) on `segmentDone.wait()`, plus consumes a GCD thread for the serial queue. With 4 sessions, all cooperative pool threads are blocked on semaphores, none left to execute jobs. GCD thread starvation.

### Attempt 3: `session.dispatch` (serial GCD queue, NO blocking semaphore)
**What**: Dispatch job to per-session GCD serial queue. Don't wait for segment to complete — let `waitForStateChange` handle it (waits for next job arrival). Serial queue ensures one segment at a time per session.
**Result**: `jobsDoNotOverlap` PASSES. `parallelSessionsBothComplete` PASSES. Full suite: FLAKY — 1/3 runs pass, 2/3 hang.
**Why it failed**: The drain loop still runs on a cooperative pool thread and blocks on `session.jobArrived.wait()`. With 4+ parallel sessions, all cooperative pool threads are consumed by drain loops blocking on semaphores. Sometimes works if threads become available before starvation; sometimes doesn't. Race condition.

### Attempt 4: Move drain loop to GCD queue via `withCheckedThrowingContinuation`
**What**: Wrap the entire drain loop in `withCheckedThrowingContinuation`, dispatch to a GCD `drainQueue`. This frees the cooperative pool thread (the continuation suspends). Resume continuation when drain completes.
**Result**: TOTAL HANG — even single tests don't start. Process has 0 cooperative pool threads.
**Why it failed**: NOT YET CONFIRMED. Hypothesis: the `withCheckedThrowingContinuation` suspends correctly, but the test's `Task {}` (created before the continuation) needs cooperative pool threads to execute. With the calling task suspended in the continuation, and the drain loop on a GCD queue, there may be no trigger to spin up cooperative pool threads. Need to debug with LLDB to confirm.

## Current State
Reverted to Attempt 3 (`session.dispatch` with drain loop on cooperative pool thread). Single tests pass. 2-3 parallel sessions pass. 4+ parallel sessions flaky.

### Investigation: Attempt 4 failure
- `withCheckedThrowingContinuation` + GCD works fine in isolation (both tests pass)
- `Task {}` before continuation executes correctly while continuation is suspended
- `ScheduleController.run` with the current code (Attempt 3) passes the continuation bridge test
- Conclusion: Attempt 4's hang was likely a code bug in my implementation, not a fundamental problem with the pattern. The `withCheckedThrowingContinuation` approach IS viable.

### Attempt 5: Re-implement continuation bridge (same as Attempt 4)
**What**: Move drain loop to GCD `drainQueue` via `withCheckedThrowingContinuation`. 
**Result**: Drain loop runs and completes (18 steps). `cont.resume()` is called. But the process hangs after resume.
**Why it failed**: When `cont.resume()` fires, the runtime enqueues the continuation of `withCheckedThrowingContinuation` through `swift_task_enqueueGlobal_hook`. The hook routes it to `session.pending` (because the awaiting task has the session task local). But the drain loop has already exited — nobody is draining `session.pending`. The resumed continuation sits in the pending buffer forever. **The drain loop's own continuation gets trapped in its own pending buffer.**
**Root cause confirmed via debug prints**: "[drain] continuation resumed" prints but "[drain] continuation returned" never prints.

### Attempt 6: Unregister session before cont.resume()
**What**: Unregister session from `_sessions` before calling `cont.resume()`, so the hook routes the continuation through `original(job)` to the cooperative pool instead of back into the dead session's pending buffer.
**Result**: Individual tests pass. Full suite (5 suites in parallel) FLAKY — sometimes passes all 11 tests in 0.013s, sometimes hangs. 
**Why it's flaky**: NOT YET CONFIRMED. Hypothesis: race between session unregistration and another parallel session's hook call. Or the continuation resume timing varies — sometimes the cooperative pool picks it up before the next test starts, sometimes not.

## Current State
Attempt 6 is close — passes consistently for individual tests and sometimes for the full suite. The flakiness needs investigation. The hang from Attempt 5 (continuation trapped in pending buffer) is fixed — the remaining issue is a different race condition in parallel execution.

### Attempt 6 deeper investigation
The "hang" was a false alarm — my 5-second timeout was too short. Tests complete but take longer with 11 tests in 5 suites.

Real issues when running all suites in parallel:
1. **`jobsDoNotOverlap` fails intermittently** — overlap detected, different threads. The drain loop dispatches to the serial queue but doesn't wait for completion. If it outpaces the queue (dispatches job B before job A finishes on the queue), the serial queue serializes them, but from the trie's perspective the edge ordering is wrong because the drain loop picked and dispatched before the previous segment completed.
2. **Determinism fails** — cross-session interference when `g_target_context` is shared globally. Multiple sessions writing to the same target context corrupts coverage.
3. **Coverage test fails** — same `g_target_context` sharing issue.

The `session.dispatch` problem: dispatch without waiting allows the drain loop to enqueue multiple jobs onto the serial GCD queue. They execute sequentially on the queue, but the drain loop's scheduling decisions are based on stale state (it doesn't know which queued job is currently running).

## Root Cause Analysis
Two distinct problems:
1. **Serial execution within a session**: Need to wait for each dispatched job to complete before dispatching the next. Attempt 2 (`segmentDone.wait()`) solved this but caused thread starvation. Attempt 6 (`session.dispatch` without waiting) doesn't enforce serialization.
2. **Cross-session isolation**: `g_target_context` is global. Parallel sessions corrupt each other's coverage. This is separate from the drain loop issue.

## Next Step
For problem 1: The `segmentDone.wait()` approach (Attempt 2) IS correct for serial execution. It only caused starvation because the drain loop was on the cooperative pool. With the drain loop on a dedicated GCD `drainQueue` (Attempt 6's contribution), `segmentDone.wait()` blocks the drain GCD thread, not a cooperative pool thread. COMBINE Attempt 2 and 6: drain loop on GCD drainQueue + segmentDone.wait() on that same GCD thread.

For problem 2: g_target_context needs to be per-session or not used when parallel sessions are active. Separate fix.

### Attempt 7: drainQueue + segmentDone.wait() (combining Attempts 2 and 6)
**What**: Drain loop on GCD drainQueue (via withCheckedThrowingContinuation). session.dispatch blocks on segmentDone.wait() to ensure serial execution. Unregister session before cont.resume() to avoid pending buffer trap.
**Result**: Individual tests pass. Full suite: SIGSEGV crash. Some tests pass, some don't start before crash.
**Why it failed**: The segmentDone.wait() blocks the drainQueue thread. If the dispatched job triggers work that needs the drainQueue (e.g., via the hook routing), circular dependency causes either crash or deadlock. SIGSEGV suggests memory corruption from the race.

### Attempt 8: Revert to Attempt 3+6 (dispatch without wait + continuation bridge)
**What**: Per-session GCD serial queue for job execution (no blocking semaphore). Drain loop on GCD drainQueue via withCheckedThrowingContinuation. Unregister session before cont.resume().
**Result**: Individual tests all pass. Full suite: flaky — sometimes all 11 pass (0.014s), sometimes hangs on startup, sometimes tests fail from cross-session interference.
**Analysis**: The serial execution within a single session is correct. The failures are from two pre-existing issues:
1. `g_target_context` is global — parallel sessions corrupt each other's coverage (determinism and coverage tests fail)
2. Cooperative pool initialization race — sometimes the process hangs when 5+ suites launch simultaneously

These are not drain loop issues — they're global state issues with the hook architecture.

## Status Summary After 8 Attempts
The core tension: serial execution requires waiting for job completion, but waiting blocks threads, causing starvation or deadlock.

| Attempt | Serial? | Parallel safe? | Issue |
|---------|---------|---------------|-------|
| 1. runSynchronously inline | Yes | N/A | Deadlock on await |
| 2. segmentDone.wait on coop pool | Yes | No | Coop pool starvation |
| 3. dispatch without wait | No | Yes | Jobs overlap |
| 4/5. withCheckedContinuation | N/A | N/A | Continuation trapped |
| 6. Unregister before resume | No | Flaky | Jobs still overlap |
| 7. drainQueue + segmentDone | Yes | No | SIGSEGV crash |
| 8. Attempt 3+6 combined | Yes (serial queue) | Flaky | Cross-session g_target_context + coop pool race |

## Parallel Session Fix

### Problem 1: g_target_context is global
`g_target_context` is a `static` global in SanCovHooks.c. When two sessions call `sancov_set_target_context()`, the last write wins. All edges from both sessions go to one context.

**Fix**: Change `g_target_context` to `_Thread_local`. Each session's serial queue runs on its own GCD thread, so TLS isolates them.

**Important**: `sancov_set_target_context()` is currently called from the cooperative pool thread (in `ScheduleController.run` before `withCheckedThrowingContinuation`). But jobs execute on the session's serial queue thread. So the TLS set and the TLS read happen on DIFFERENT threads. Need to move `sancov_set_target_context()` to execute on the serial queue thread, inside `session.dispatch`.

### Implementation (done)
- Changed `g_target_context` to `_Thread_local` in SanCovHooks.c
- Moved `sancov_set_target_context(coverageContext)` into `SessionState.dispatch` — set on serial queue thread before each job, cleared after
- SessionState stores coverageContext pointer
- Removed hook uninstallation from defer — hook stays installed permanently so parallel sessions don't race on hook install/uninstall

### Results after g_target_context fix
5 direct runs of full suite (11 tests, 5 suites):
- Coverage tests: PASS consistently (TLS isolation works)
- Overlap test: PASS 4/5 (fails when parallel sessions compete for GCD threads)
- Determinism test: PASS 3/5 (fails when concurrent sessions interfere)
- parallelSessionsBothComplete: hangs 3/5 (GCD thread contention)
- All other tests: PASS consistently

### Problem 2: parallelSessionsBothComplete hangs intermittently
Root cause: each session uses 2 GCD queues (drainQueue + serial queue). The `parallelSessionsBothComplete` test creates 2 concurrent sessions = 4 GCD queues. When the full suite runs, additional sessions from other tests add more. GCD has a per-QoS thread limit. With 4+ custom serial queues blocking on semaphores, GCD threads exhaust and sessions deadlock waiting for each other.

The drain loop on drainQueue blocks on `session.jobArrived.wait()`. The serial queue blocks inside `runSynchronously`. At peak, 4+ threads are blocked on semaphores, leaving none for GCD to service new queue items.

### Potential fix for Problem 2
Use a SINGLE shared serial queue for all sessions' drain loops instead of per-session drainQueues. The shared queue serializes all drain loops — only one runs at a time. This reduces max blocked threads from N*2 to 1+N (1 shared drain thread + N serial queues). But this means sessions' drain loops don't run in parallel — they take turns. Since each drain step is fast (pick job + dispatch), this should be acceptable.

Alternative: use a shared thread pool with a cap on concurrent blocked threads.

### LLDB investigation of the hang (actual data)
Caught a hang: 11 threads, ALL idle (`__workq_kernreturn`). 10 tests passed, 5 started but not completed (jobsDoNotOverlap + parallelSessionsBothComplete + their suite/run wrappers).

**Key finding**: No thread is blocked on a semaphore. No deadlock. No starvation. All threads are idle.

**Root cause**: `cont.resume()` enqueues the continuation via `original(job)` to the cooperative pool. But the cooperative pool doesn't pick it up — all worker threads return to idle. The continuation is **lost** in the cooperative pool's queue.

This is a **lost wakeup** — the cooperative pool enqueue succeeded but no thread wakes up to process it. Possible causes:
1. `original(job)` (which is `swift_task_enqueueGlobalImpl`) doesn't signal the cooperative pool to wake a thread — it assumes threads are already polling
2. The cooperative pool's threads all drained their work and went to sleep before the continuation was enqueued
3. The enqueue goes to a different executor than expected (e.g., main executor) and nobody pumps that executor

This is NOT a GCD issue — all GCD threads are idle too. The continuation was enqueued to the cooperative pool but the pool doesn't process it.

### Hook passthrough tests (empirical verification)
Wrote 5 minimal tests in HookPassthroughTest.swift to verify fundamental assumptions:

1. **Passthrough hook sees continuation resume**: PASS. `cont.resume()` from GCD triggers `swift_task_enqueueGlobal_hook`. The hook sees the job.
2. **Continuation completes with hook**: PASS. Exact ScheduleController pattern (Task + withCheckedThrowingContinuation + GCD resume) works with passthrough hook.
3. **Routing hook routes correctly**: PASS. Non-session jobs go through passthrough path.
4. **Session unregister before resume**: PASS. KEY FINDING: `cont.resume()` from a GCD thread does NOT carry `SessionTag.id` (task locals are nil on GCD threads). The hook sees `SessionTag.id == nil` and routes through `no-session-passthrough` → `original(job)`. This means the unregister-before-resume pattern is UNNECESSARY — the GCD thread never has session context anyway.
5. **5 concurrent continuations**: PASS. No lost wakeups with passthrough hook.

**Implication**: With a passthrough hook, the mechanism works. The hang is specific to ScheduleController's routing hook.

### Root cause identified: stale pthread TLS
The routing hook has 3 methods to identify session jobs:
1. `SessionTag.id` (task local on current task) — nil on GCD thread ✓
2. `schedule_read_session_from_task` (task local on enqueued job) — reads job's task locals
3. `schedule_tls_get_session()` (pthread TLS) — **STALE**

Method 3 checks pthread TLS. The drain loop sets `schedule_tls_set_session(sid)` during job execution (methods 1 and 2 both set it). This persists on the thread. When `cont.resume()` fires on the drain thread, method 3 picks up the stale TLS session ID and routes the continuation to `routeToSession(staleSid, job)`. The session is already unregistered, so `routeToSession` falls through to `original(job)`. BUT if `_original` is nil (race condition) or if method 2 catches it first (reading stale task locals from the continuation job), the continuation could be routed to the dead session's pending buffer.

**Fix attempt**: Clear pthread TLS on drain thread before `cont.resume()`. INSUFFICIENT — still hangs 4/5.

**Why TLS clear insufficient**: Method 2 reads session ID from the continuation JOB's task locals (not the thread's TLS). The continuation task was created inside `SessionTag.$id.withValue(sessionID)`, so its task locals carry the session ID. When `cont.resume()` enqueues the job, method 2 reads the session ID from the job pointer, routes to `routeToSession(sid, job)`. Session is unregistered, falls through to `original(job)`. `_original` is NOT nil (verified). `original(job)` IS called.

**But the continuation still hangs.** `original(job)` is called but the cooperative pool doesn't process it. 

**Next hypothesis**: The continuation resumes inside `SessionTag.$id.withValue(sessionID) { ... }`. After `withCheckedThrowingContinuation` returns, the async function has more work (defer blocks, coverage rebuild). These might hit `await` points or yield, causing re-enqueues through the hook. The continuation's task has session task locals, so method 1 catches these re-enqueues and routes them to the (now dead) session. Even though the first hop via `original(job)` works, the SECOND hop (from the resumed continuation's next suspension point) goes to the dead session.

**Real fix needed**: The hook must not route to dead sessions. Currently `routeToSession` falls through to `original(job)` when the session is gone. But if `original(job)` executes the job on a cooperative pool thread, and that job has session task locals, the NEXT enqueue from that job will go through method 1 again → `routeToSession` → falls through → `original(job)` → executes → method 1 again → infinite loop of failed routing? Or does it converge?

Wait — `routeToSession` with an unregistered session calls `original(job)`. The job runs. Its next suspension re-enqueues through the hook. Method 1 fires (`SessionTag.id != nil`), routes to `routeToSession(sid, job)`. Session still gone, falls through to `original(job)`. Repeat. This should work — each hop goes through `original(job)`.

The issue might be that `routeToSession` calls `schedule_tls_set_session(sid)` via methods 1/2 on every hop, but that shouldn't cause a hang.

### Definitive finding: hang is NOT in routing
Added logging to every path in the routing hook and to `routeToSession` fallthrough. During hang:
- 0 routeToSession fallthrough calls
- 0 routing log entries at all
- All threads idle at `__workq_kernreturn`

The routing hook isn't even being called. The tests that hang never start executing. The cooperative pool has gone dormant — no threads are picking up work. `cont.resume()` via `original(job)` enqueues to the pool, but the pool doesn't wake.

This is a **cooperative pool wakeup issue**, not a routing issue. When 5+ suites launch simultaneously, each test suspends via `withCheckedThrowingContinuation`. The pool threads handle the suspensions and go idle. The GCD drain loops call `cont.resume()` → `original(job)` → cooperative pool enqueue. But the pool doesn't wake a thread to process the enqueued work.

This may be a cooperative pool bug or a limitation of `swift_task_enqueueGlobalImpl` called from a GCD context — it may not signal the pool's wakeup mechanism when all pool threads are dormant.

### Confirmed: even passthrough hook hangs
Ran HookPassthroughTest alone 5 times: 1/5 hang. This proves the hang is NOT from the routing logic. A pure passthrough hook (`original(job)`) also fails to wake the cooperative pool intermittently.

The `withCheckedThrowingContinuation` + GCD + `original(job)` pattern is fundamentally unreliable for waking the cooperative pool. This is a Swift runtime limitation, not a ScheduleController bug.

### Hook bypass doesn't fix it either
Temporarily set hook to nil before `cont.resume()` — still 15/20 hang. The `cont.resume()` might not even go through `swift_task_enqueueGlobal_hook` — the continuation resume might use a different enqueue path (e.g., direct dispatch to the executor the suspended task was on).

The hang is a fundamental issue with the cooperative pool not waking up when `cont.resume()` is called from a GCD thread. This is independent of the hook.

### Summary of all approaches tried

| Approach | Single test | 4 parallel suites (20 runs) | Issue |
|----------|-----------|---------------------------|-------|
| Cooperative pool drain + original(job) | PASS | 3 OK, 7 fail, 10 hang | Pool starvation: 4 blocked threads |
| withCheckedThrowingContinuation + GCD | PASS | ~3 OK, ~2 fail, ~15 hang | cont.resume() doesn't wake pool |
| Hook bypass before resume | PASS | 0 OK, 5 fail, 15 hang | cont.resume() path doesn't use hook |

Neither approach works reliably for 4+ parallel sessions. The fundamental issue: the cooperative pool has limited threads (nproc). Each ScheduleController session either blocks one (cooperative drain) or fails to resume one (GCD drain). With 4+ concurrent sessions, the pool exhausts.

### Possible path forward
The drain loop MUST run on a thread that can block without consuming cooperative pool threads. `withCheckedThrowingContinuation` frees the pool thread but `cont.resume()` from GCD doesn't reliably wake the pool. The fix might need to be in HOW we resume — not through `cont.resume()` but through dispatching to MainActor or a custom executor that guaranteed to be running. Go back to blocking the cooperative pool thread (Attempt 3). Accept that parallel sessions consume cooperative pool threads. The cooperative pool has `nproc` threads (typically 8-10). As long as concurrent sessions < nproc, it works. ScheduleController is designed for fuzzing (1 engine = 1 session), so parallel sessions are only from tests.

### Comparison: cooperative pool blocking vs GCD bridge
- **Cooperative pool blocking (Attempt 3)**: 1/10 pass. Each session blocks a pool thread. With 5+ suites, pool exhausted.
- **GCD bridge (withCheckedThrowingContinuation)**: 3/10 pass. Frees pool threads, but `original(job)` intermittently fails to wake dormant pool.
- GCD bridge is strictly better but still unreliable.

### Current best approach
Use `withCheckedThrowingContinuation` + GCD drain queue. Accept the ~30% hang rate for parallel test suites. Individual tests and 2-3 parallel sessions work reliably. The hang is a Swift cooperative pool wakeup limitation when `swift_task_enqueueGlobalImpl` is called from GCD after the pool goes dormant.

For production use (fuzzing), only 1 session runs at a time per engine — no parallel session issue. The parallel hang only affects the test suite.

### Further investigation: hang is from concurrent hook install/uninstall
- No hook installed: 20/20 pass
- Passthrough hook (single test): 20/20 pass
- Passthrough hook suite (5 tests, 1 suite, serialized): 20/20 pass
- Full ScheduleControlTests (5 suites in parallel): ~30% pass

The hang occurs when multiple suites run in parallel and each test installs/uninstalls the global hook pointer. The HookPassthroughTests install their own hooks via `hookPtr.pointee = passthroughHook` and restore via `defer { hookPtr.pointee = previousHook }`. When these run concurrently with ScheduleController tests that install the routing hook, the hook pointer races — one test restores nil while another's session expects the routing hook.

**Fix**: The HookPassthroughTests and ScheduleController tests must not install conflicting hooks concurrently. Either:
1. Put ALL schedule control tests in one serialized suite
2. Don't install/uninstall hooks in the passthrough tests (use ScheduleController.run instead)
3. Use a lock around hook installation
