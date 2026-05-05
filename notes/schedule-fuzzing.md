# Schedule-Aware Fuzzing for Concurrent Code

## Problem

Coverage-guided fuzzing of concurrent/async code suffers from nondeterministic
scheduling. The same input produces different coverage on different runs because
OS/runtime scheduling decisions vary. This causes:

1. **Corpus inflation**: Same logical input saved multiple times with different
   coverage signatures (observed: 12/14 corpus entries identical in GenericTimerPoller
   concurrent test before edge filter)
2. **Regression instability**: Saved coverage never matches replay coverage,
   triggering spurious re-fuzz on every run (observed: edge 673, the subscribe
   callback in executeLane, fires based on async task scheduling)
3. **Wasted mutations**: Energy spent on duplicates instead of genuinely novel inputs

No published research addresses filtering or correcting coverage noise from
uncontrolled nondeterminism. Everyone says "make your target deterministic."

## ConFuzz Approach (PADL 2021)

**Paper**: "ConFuzz: Coverage-Guided Property Fuzzing for Event-Driven Programs"
by Andreas Zeller, Rahul Gopinath, Marcel Boehme, Gordon Fraser, Christian Holler
(Springer LNCS 12548)

**Local copy**: `/Users/alex.reilly/Downloads/978-3-030-67438-0_8.pdf`

### Core idea

Make the schedule part of the fuzzed input. AFL generates random bytes that
control callback execution order. Coverage feedback then guides AFL toward
*schedules* that hit new code paths.

### How it works (OCaml/Lwt)

Lwt is a single-threaded cooperative concurrency library for OCaml. ConFuzz
replaces Lwt's event loop scheduler with a controlled one:

- `fuzz_list : 'a list -> 'a list` — takes pending callbacks, returns them
  shuffled using AFL-provided random bytes
- Applied at three interception points:
  1. **Event loop queues** (yield, pause, I/O callbacks) — shuffled before each
     event loop iteration
  2. **Worker pool** — reduced to single thread, tasks delayed by one iteration
     then shuffled as a batch
  3. **Promise callbacks** — shuffled before resolution

### Key properties

- Schedule is encoded in AFL's input bytes, so bugs are **deterministically
  reproducible** — replay same bytes, get same schedule
- All explored schedules are legal Lwt schedules (just reordered), so **no
  false positives**
- Coverage guides toward schedules that exercise new code, not just random
  shuffling

### Results

- Found Node.js CVEs that random scheduling (Node.Fz) and stress testing missed
- Schedule-space coverage complements code coverage — ConFuzz finds bugs in code
  that's already fully covered by sequential tests

## Mapping to Swift Concurrency

### What maps cleanly

| Lwt concept | Swift equivalent |
|---|---|
| Cooperative event loop | Cooperative executor |
| Yield/pause queues | Task ready queue |
| `fuzz_list` shuffle | Custom `SerialExecutor` reordering job dispatch |
| Schedule as fuzzed input | `[Int]` schedule parameter alongside fuzz inputs |
| Promise callbacks | Task continuations |

### What's hard

1. **Threading model mismatch**: Lwt is single-threaded cooperative. Swift's
   global concurrent executor is multi-threaded. ConFuzz's "reduce to 1 thread"
   works for Lwt because worker pool tasks are a separate category. In Swift,
   everything goes through the cooperative thread pool.

2. **Executor pluggability**: Custom `SerialExecutor` works per-actor, but the
   **global concurrent executor** isn't pluggable from user code. No
   `SWIFT_DETERMINISTIC_SCHEDULING` equivalent exists.

3. **Continuation opacity**: Lwt callbacks are explicit closures in a list that
   ConFuzz can see and reorder. Swift task continuations are opaque to user code —
   the runtime manages them internally.

### Possible Swift approach

Use a custom `SerialExecutor` that all test actors adopt:

```swift
final class FuzzScheduler: SerialExecutor {
    var pendingJobs: [UnownedJob] = []
    var permutation: [Int]  // from fuzz input

    func enqueue(_ job: consuming ExecutorJob) {
        pendingJobs.append(UnownedJob(job))
    }

    func drain() {
        let ordered = applyPermutation(pendingJobs, permutation)
        for job in ordered {
            job.runSynchronously(on: asUnownedSerialExecutor())
        }
        pendingJobs.removeAll()
    }
}
```

- GenericTimerPoller (an actor) would use this executor
- The fuzz input would include a permutation controlling drain order
- Subscribe callbacks would fire deterministically based on fuzz input
- Coverage of schedule-dependent paths would be reproducible

**Limitation**: Only covers actor-isolated code. Unstructured `Task {}` and
`TaskGroup` scheduling still goes through the global executor and remains
nondeterministic.

### Open questions

- Does `SerialExecutor.enqueue` give us enough control? Can we batch and
  reorder, or does the runtime expect immediate execution?
- Could we use `TaskExecutor` (SE-0417, Swift 6.0) for broader control?
- Would a single-threaded global executor via `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1`
  be sufficient to serialize all tasks for testing purposes?
- How does this interact with pathTrie? If schedule is part of the input,
  different schedules for the same program input produce different paths in the
  trie — which is exactly what we want.

## AFL++ Approach (for comparison)

AFL++ handles nondeterminism reactively, not proactively:

- Replays each corpus entry 8 times during calibration
- Bytes in the trace bitmap that differ across runs are marked `var_bytes`
- Variable bytes are set to "fully discovered" in `virgin_bits` (zeroed out)
- These edges are **ignored for all future coverage decisions**
- Stability metric: percentage of stable edges. Below 90% is concerning.

This is simpler but loses information — an edge that's variable is never
considered interesting again, even if it becomes stable later.

## Our Current Mitigations

1. **Compiler-generated edge filter** (`sancov_apply_edge_filter`): Filters
   outlined destroyers, lazy witness table accessors, etc. by setting guard to
   UINT32_MAX. Handles ~2260 edges in a typical test binary. Zero hot-path cost.

2. **Unordered regression comparison** (`coverageChanged`): Set-based strategies
   (signatureMatch, newEdge) compare sorted indices rather than ordered arrays.
   Handles edge ordering nondeterminism but not presence/absence nondeterminism.

3. **Strategy-specific workarounds**: Tests with known nondeterminism use
   `coverageStrategy: .newEdge` to minimize (but not eliminate) the impact.

## How Other Tools Handle Concurrent Fuzzing

### ThreadSanitizer (TSan)

TSan is a passive race detector (vector clocks, shadow memory). It does NOT
control scheduling. As of 2025, it gained optional **adaptive delay scheduling**
(PR #178836) — randomized delays injected at synchronization points (atomics,
mutex lock/unlock, thread creation) to perturb timing and expose races.

- Not a scheduler — random timing nudges, no feedback loop, no replay
- Dvyukov (TSan author) explicitly rejected full serialization, capped overhead
  at 10-20%
- Relevant insight: TSan's delay injection points (sync operations) inform where
  a Swift concurrency fuzzer would place scheduling decisions

### Go Fuzzer + Goroutines

Go's built-in fuzzer uses global 8-bit counters shared across all goroutines.
No per-goroutine tracking, no scheduler control. Official guidance: fuzz targets
"should be fast and deterministic."

- The old `dvyukov/go-fuzz` forced `GOMAXPROCS=1` (serialize everything) and
  acknowledged concurrent fuzzing was unsupported
- Go issue #46410: background goroutines pollute coverage signals. Fix: exclude
  noisy packages (`runtime`, `sync`, `time`) from instrumentation — same
  approach as our edge filter, just coarser-grained
- **GFuzz** (ASPLOS 2022, "Who Goes First?") is the real answer for Go: fuzzes
  channel message orderings rather than input bytes. Found 184 bugs in Docker,
  Kubernetes, gRPC. Patches the Go runtime — research-grade.

### Rust Loom

Exhaustive deterministic model checker via type substitution. Replace
`std::sync::Mutex` with `loom::sync::Mutex` via `#[cfg(loom)]`. Loom runs the
test many times, making deterministic scheduling choices at every instrumented
operation. Single-threaded — only one logical thread executes at a time.

- Uses DPOR (Dynamic Partial Order Reduction) from CDSChecker (OOPSLA 2013)
- Does NOT control async task scheduling — operates at thread + atomic level
- Tokio uses Loom internally to test its scheduler *implementation*, not to test
  async user code
- **Shuttle** (AWS) is Loom's practical cousin: randomized PCT-based scheduling,
  has its own async executor, scales to larger programs

**Not adaptable to Swift directly.** Loom's core trick (type substitution via
conditional compilation) has no Swift equivalent. Swift concurrency is
language-integrated (`actor`, `async let`, `TaskGroup`), not a swappable library.

### Summary

| Tool              | Controls scheduler? | Handles async? | Adaptable to Swift? |
|-------------------|---------------------|----------------|---------------------|
| TSan delay        | No (random nudges)  | No             | Partially (concept) |
| Go fuzzer         | No                  | N/A            | Already doing this  |
| Loom              | Yes (DPOR)          | No (threads)   | No (type subst.)    |
| Shuttle (PCT)     | Yes (random+replay) | Yes (executor)  | Most promising      |
| GFuzz/RFF/ConFuzz | Yes                 | Varies         | Requires hooks      |

## Schedule Fuzzing via `swift_task_enqueueGlobal_hook`

### Swift runtime hooks (verified against source)

Source: `swift/include/swift/Runtime/ConcurrencyHooks.def`,
`swift/stdlib/public/Concurrency/ConcurrencyHooks.cpp`

The Swift runtime exposes hookable function pointers via
`SWIFT_CONCURRENCY_HOOK` macros. Each hook is a global nullable function
pointer initialized to `nullptr`. When non-null, the runtime calls the hook
instead of the default implementation, passing the original as the last
argument.

**All hooks (ConcurrencyHooks.def):**

| Hook                                              | Signature (params before `original`)                    |
|---------------------------------------------------|---------------------------------------------------------|
| `swift_task_enqueueGlobal_hook`                   | `Job *job`                                              |
| `swift_task_enqueueGlobalWithDelay_hook`           | `unsigned long long delay, Job *job`                    |
| `swift_task_enqueueGlobalWithDeadline_hook`        | `long long sec/nsec/tsec/tnsec, int clock, Job *job`    |
| `swift_task_enqueueMainExecutor_hook`              | `Job *job`                                              |
| `swift_task_getMainExecutor_hook`                  | (none — returns `SerialExecutorRef`)                    |
| `swift_task_isMainExecutor_hook`                   | `SerialExecutorRef executor`                            |
| `swift_task_checkIsolated_hook`                    | `SerialExecutorRef executor`                            |
| `swift_task_isIsolatingCurrentContext_hook`         | `SerialExecutorRef executor`                            |
| `swift_task_isOnExecutor_hook`                     | `HeapObject *executor, Metadata*, WitnessTable*`        |
| `swift_task_donateThreadToGlobalExecutorUntil_hook`| `bool (*condition)(void*), void *context`               |

**There is no `swift_task_enqueueOnExecutor_hook`.** The function
`_swift_task_enqueueOnExecutor` exists (Actor.cpp, Executor.swift) but has no
hook variable. Actor-targeted enqueues cannot be intercepted via a hook.

### What `swift_task_enqueueGlobal_hook` actually intercepts

The central dispatch function is `swift_task_enqueueImpl` (Actor.cpp:2677).
It receives a `Job*` and `SerialExecutorRef` and branches:

```
swift_task_enqueueImpl(Job *job, SerialExecutorRef executor):

  if executor.isGeneric():              // no specific executor target
    → swift_task_enqueueGlobal(job)       ← HOOKED

  if executor.isDefaultActor():         // plain `actor MyActor {}`
    → swift_defaultActor_enqueue(job)     // adds to actor's MPSC queue
      → if actor was idle:
          scheduleActorProcessJob()
            → swift_task_enqueueGlobal(processJob)  ← HOOKED

  else:                                 // custom SerialExecutor (incl MainActor)
    → _swift_task_enqueueOnExecutor()     // calls executor.enqueue() directly
                                          // NOT hooked
```

Key insight: **default actors request processing threads via
`swift_task_enqueueGlobal`**. When a default actor is idle and receives a job,
`DefaultActorImpl::enqueue` (Actor.cpp:1556) transitions the actor to
"scheduled" state and calls `scheduleActorProcessJob` (Actor.cpp:1533), which
creates a `ProcessOutOfLineJob` and enqueues it on the global executor. This
goes through the hook.

What this means for schedule fuzzing:

| What happens                          | Goes through global hook? |
|---------------------------------------|---------------------------|
| `Task { }` / `Task.detached { }`     | Yes — directly            |
| `TaskGroup.addTask { }`              | Yes — directly            |
| Default actor needs processing thread | Yes — via `scheduleActorProcessJob` |
| Jobs queued on already-busy actor     | No — drained by existing thread |
| MainActor-targeted jobs               | No — separate `swift_task_enqueueMainExecutor_hook` |
| Custom `SerialExecutor` enqueues      | No — `_swift_task_enqueueOnExecutor`, unhookable |

**The global hook controls when actors get processing time**, which is
sufficient for controlling interleavings between concurrent tasks and actor
method calls.

### Point-Free's approach (reference implementation)

Source: `swift-concurrency-extras/Sources/ConcurrencyExtras/MainSerialExecutor.swift`

```swift
// Hook access via dlsym
private typealias Original = @convention(thin) (UnownedJob) -> Void
private typealias Hook = @convention(thin) (UnownedJob, Original) -> Void

private let _swift_task_enqueueGlobal_hook = UncheckedSendable(
    dlsym(dlopen(nil, 0), "swift_task_enqueueGlobal_hook")
        .assumingMemoryBound(to: Hook?.self)
)

// Installation: redirect all global enqueues to MainActor
swift_task_enqueueGlobal_hook = { job, _ in MainActor.shared.enqueue(job) }
```

This serializes ALL work (including default actor processing) onto the main
thread in FIFO order. Deterministic but cannot explore different interleavings.

### Design: ConFuzz model adapted for Swift

Same approach as Point-Free but with fuzz-controlled ordering instead of FIFO.

**Hook installation (Swift, using dlsym pattern):**

```swift
// Buffer jobs instead of dispatching immediately
var pending: [(UnownedJob, Original)] = []

swift_task_enqueueGlobal_hook = { job, original in
    pending.append((job, original))
}
```

**Controlled drain loop (single-threaded, fuzz-driven):**

```
scheduleBytes: [UInt8]  // from fuzz input
index = 0

// Must run on MainActor — cannot use original(job) because it
// re-enters the cooperative pool instead of executing synchronously.
// MainActor.shared.enqueue + RunLoop.main.run executes each job inline.
while !completion.isCompleted {
    let count = pending.count
    if count == 0 { RunLoop.main.run(briefly); continue }
    let choice = Int(scheduleBytes[index]) % count
    index += 1
    let job = pending.remove(at: choice)
    MainActor.shared.enqueue(job)
    RunLoop.main.run(briefly)
    // execution may enqueue more jobs via the hook → pending grows
}
```

**Concrete example with GenericTimerPoller:**

```swift
await withTaskGroup(of: Void.self) { group in
    group.addTask { await executeLane(input.lane1, on: poller) }
    group.addTask { await executeLane(input.lane2, on: poller) }
}
```

With schedule bytes `[0, 1, 0, 1, ...]`:

1. `addTask(lane1)` → hook fires, pending = `[lane1_start]`
2. `addTask(lane2)` → hook fires, pending = `[lane1_start, lane2_start]`
3. Parent suspends at `for await in group`
4. Scheduler picks `byte[0]=0 → 0%2=0` → runs `lane1_start`
5. Lane1 calls `await poller.subscribe()` → job queued on actor → actor idle →
   `scheduleActorProcessJob` → hook fires, pending =
   `[lane2_start, actor_process_job]`
6. Scheduler picks `byte[1]=1 → 1%2=1` → runs `actor_process_job`
7. Actor drains its queue (processes subscribe), lane1 continuation resumes,
   new job enqueued via hook
8. ...and so on

Different schedule bytes → different interleaving → different coverage.
Deterministic replay: same bytes = same schedule = same coverage.

### Limitation: intra-actor ordering

When multiple jobs are queued on an already-busy default actor, they are
drained in FIFO order by the existing processing thread — the global hook
doesn't fire again for those jobs. This means:

- **Inter-actor/inter-task ordering**: fully controllable via the hook
- **Intra-actor job ordering**: FIFO, not controllable

For GenericTimerPoller this is fine — the interesting nondeterminism is in the
interleaving of concurrent lanes, not in the order of jobs within the actor's
queue (which is serial by design).

### Schedule as implicit fuzz dimension

The user doesn't see the schedule — it's an internal fuzz dimension:

```swift
// User writes exactly what they write today:
try await fuzz(duration: .seconds(30)) { (input: PollerFuzzInput) in
    let poller = GenericTimerPoller(...)
    await withTaskGroup(of: Void.self) { group in
        group.addTask { await executeLane(input.lane1, on: poller) }
        group.addTask { await executeLane(input.lane2, on: poller) }
    }
}
```

Internally, the fuzzer:
- Generates schedule bytes alongside data input
- Installs the hook before each iteration
- Mutates schedule bytes independently (byte flips, like AFL havoc)
- Coverage guides both data mutations and schedule mutations
- Corpus entries store `(data_input, schedule_bytes)` for replay

### Resolved questions

1. **Can we hold a Job and dispatch it later?** ✅ Yes. Jobs are heap-allocated
   and the runtime tolerates non-immediate dispatch. Use `original(job)` to
   dispatch to the cooperative pool asynchronously.

2. **Execution model.** ✅ Resolved empirically. `MainActor.shared.enqueue(job)`
   does NOT work — it deadlocks when called from inside `MainActor.run` (holds
   executor lock). `_runSynchronously(on:)` also fails. `original(job)` works:
   dispatches to the cooperative pool, job runs on a pool thread. The drain loop
   runs on a dedicated dispatch queue (NOT the cooperative pool) and uses a
   `DispatchSemaphore` to synchronize. After each `original(job)`, the drain
   waits until either new jobs appear in the pending buffer (meaning the job
   suspended) or the test completes.

3. **Reentrancy in the hook.** ✅ Not an issue. The hook just appends to the
   lock-protected pending buffer and signals a semaphore. The drain loop picks
   up new jobs on the next iteration.

4. **When to enable.** Resolved: explicit flag `scheduleFuzzing: true`.

5. **First-run warmup.** ⚠️ The first call to `ScheduleController.run` from
   an async context may produce a different interleaving than subsequent calls
   (cooperative pool initialization overhead). Subsequent calls are fully
   deterministic. In the fuzz loop, the first iteration serves as warmup.

### Open questions

5. **Interaction with pathTrie.** If schedule is part of the input, different
   schedules for the same data input produce different paths — which is exactly
   what we want. The path captures the interleaving, and pathTrie deduplicates
   by unique interleavings. (Needs empirical verification.)

6. **MainActor-targeted work.** Jobs going to MainActor use a separate hook
   (`swift_task_enqueueMainExecutor_hook`). If the test involves MainActor
   code, we'd need to hook both. For actor-only tests (like GenericTimerPoller),
   the global hook is sufficient since actor processing goes through it.

7. **Schedule bytes as explicit fuzz dimension.** Currently schedule bytes are
   generated fresh each iteration from the RNG, not stored or mutated
   independently. Making them a corpus dimension would enable replay and
   targeted schedule mutation.

## Implementation (completed)

### Module: `ScheduleControl`

Separate SPM target (`Sources/ScheduleControl/`) with NO `-sanitize-coverage` flags
to avoid instrumenting the hook itself (same pattern as `EdgeHooks`).

### Key implementation findings (empirically verified)

1. **`MainActor.shared.enqueue(job)` does NOT work.** It deadlocks when called
   from inside `MainActor.run` — the executor lock is held by the calling closure.
   `_runSynchronously(on:)` also fails (deprecated, doesn't execute job body).
   `CFRunLoopRunInMode` and `RunLoop.main.run` don't process MainActor-enqueued
   jobs from synchronous contexts.

2. **`original(job)` DOES work.** It dispatches the job to the cooperative pool
   asynchronously. The job runs on a pool thread until it suspends, at which
   point the hook captures the continuation. This is the correct drain mechanism.

3. **`Task.detached` fires the hook synchronously; `Task {}` may not.**
   `Task.detached` always goes through `swift_task_enqueueGlobal`. `Task {}`
   from actor context may use `swift_task_enqueueMainExecutor` instead. The test
   closure must be launched with `Task.detached`.

4. **Drain loop must NOT run on the cooperative pool.** The drain loop blocks
   on a `DispatchSemaphore` while waiting for jobs to complete. Blocking a
   cooperative thread would steal a thread from the pool that the dispatched
   job needs. Solution: run the drain loop on a dedicated `DispatchQueue`.
   The async API uses `withCheckedThrowingContinuation` to bridge.

5. **First-run warmup effect.** The first call from an async context may produce
   a different interleaving (cooperative pool initialization). Subsequent calls
   are fully deterministic with identical schedule bytes.

6. **Hook pointer needs `@unchecked Sendable` wrapper.** `UnsafeMutablePointer`
   is not `Sendable`. Wrapped in `SendablePointer` struct with safety justified
   by single-writer (ScheduleController) access pattern.

### Integration

- `FuzzEngineConfig.scheduleFuzzing: Bool` (default `false`)
- Public API: `fuzz(scheduleFuzzing: true)` on both overloads
- `FuzzStateMachine` wraps each test execution:
  ```swift
  if config.scheduleFuzzing {
      let scheduleBytes = (0..<64).map { _ in UInt8.random(in: 0...255, using: &rng) }
      try await ScheduleController.run(scheduleBytes: scheduleBytes) {
          try await testWithIssueCapture(input)
      }
  }
  ```

### Actual drain loop (verified working)

```swift
// Runs on dedicated DispatchQueue, NOT cooperative pool
_hookPtr.ptr.pointee = _bufferHook      // install hook
defer { _hookPtr.ptr.pointee = nil }

Task.detached { try await test(); completion.markCompleted() }
_jobArrived.wait()                       // wait for initial job

while !completion.isCompleted && steps < maxDrainSteps {
    let (count, original) = _state.withLock { ... }
    if count == 0 { _jobArrived.wait(...); continue }

    let choice = Int(scheduleBytes[byteIndex]) % count
    let job = _state.withLock { $0.pending.remove(at: choice) }

    original(job)                          // dispatch to cooperative pool
    waitForStateChange(completion)         // wait for new pending OR completion
}
```

The `waitForStateChange` loop checks `_state.pending.count > 0` before
returning — it doesn't rely solely on semaphore signal count, which avoids
issues with accumulated signals from runtime infrastructure jobs.

## Next steps

- Phase 2: Make schedule bytes an explicit fuzz dimension in `Mutator`/corpus
  format so they are mutated independently and stored with corpus entries for
  replay
- Test on GenericTimerPoller concurrent test: measure whether schedule-guided
  fuzzing finds the subscribe callback edge (673) reliably
- Consider hooking `swift_task_enqueueMainExecutor_hook` for tests that involve
  MainActor-targeted work
