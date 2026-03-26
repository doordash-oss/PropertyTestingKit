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

## Schedule Fuzzing via `swift_task_enqueueOnExecutor_hook`

### Swift runtime hooks

The Swift runtime exposes internal hook function pointers for task scheduling:

| Hook                                 | What it intercepts               | Actor calls? |
|--------------------------------------|----------------------------------|--------------|
| `swift_task_enqueueGlobal_hook`      | Global concurrent executor tasks | No           |
| `swift_task_enqueueOnExecutor_hook`  | All executor-targeted enqueues   | Yes          |
| Custom `SerialExecutor` on the actor | That specific actor's mailbox    | Yes (1 actor)|

Point-Free's `swift-concurrency-extras` uses `swift_task_enqueueGlobal_hook` to
redirect all global enqueues to the main actor's serial executor (FIFO
serialization). This gives deterministic scheduling but can't explore different
interleavings — it's a single fixed order.

`swift_task_enqueueOnExecutor_hook` intercepts ALL enqueues including
actor-targeted ones. This is what we want for schedule fuzzing — it covers
`Task {}`, `TaskGroup`, and `await actor.method()` uniformly.

Note: `swift_task_enqueueGlobal_hook` does NOT intercept actor calls. When you
call `await poller.subscribe()`, the runtime enqueues the job directly on the
actor's serial executor via `SerialExecutor.enqueue()`, bypassing the global
hook entirely.

### Design: ConFuzz model adapted for Swift

The approach: intercept all executor enqueues, buffer jobs, drain them
single-threaded in fuzz-controlled order.

**Hook installation:**

```c
// Hook signature (from Swift runtime):
typedef void (*swift_task_enqueueOnExecutor_hook_t)(
    Job *job,
    ExecutorRef executor,
    swift_task_enqueueOnExecutor_original original
);

// Our hook: buffer instead of dispatching
void fuzz_enqueue_hook(Job *job, ExecutorRef executor, Original original) {
    pending_queue_append(job, executor);
    signal_scheduler();
}
```

**Controlled drain loop (single-threaded, fuzz-driven):**

```
scheduleBytes: [UInt8]  // from fuzz input
index = 0

while !pending.isEmpty {
    let choice = Int(scheduleBytes[index]) % pending.count
    index += 1
    let (job, executor) = pending.remove(at: choice)
    original(job, executor)  // execute on our thread
    // execution may enqueue more jobs via the hook → pending grows
}
```

**Concrete example with GenericTimerPoller:**

```swift
// User writes the same test as today:
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
5. Lane1 calls `await poller.subscribe()` → hook fires, pending =
   `[lane2_start, subscribe_job]`
6. Scheduler picks `byte[1]=1 → 1%2=1` → runs `subscribe_job`
7. Actor processes subscribe, lane1 resumes, next op enqueued
8. ...and so on

Different schedule bytes → different interleaving → different coverage.
Deterministic replay: same bytes = same schedule = same coverage.

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

### Open questions

1. **Can we hold a Job and dispatch it later?** The hook gives us the Job
   pointer and original function. Buffering the Job and calling
   `original(job, executor)` later should work (Job is heap-allocated), but
   needs verification against runtime source. Point-Free's approach of
   redirecting enqueues proves the runtime tolerates non-immediate dispatch.

2. **Single-threaded execution.** Running everything on one thread means the
   cooperative pool is empty. Point-Free's `withMainSerialExecutor` does this
   successfully, suggesting the runtime doesn't assert on an empty pool.

3. **Reentrancy in the hook.** When we dispatch a job via `original(job, executor)`,
   that job may hit an `await` which fires the hook again inside our drain loop.
   The hook must just append to pending and return — the drain loop picks it up
   on the next iteration. Not reentrant, just queue-and-continue.

4. **When to enable.** Not all fuzz tests are concurrent. Options:
   - Explicit flag: `scheduleFuzzing: true`
   - Auto-detect: if multiple enqueues observed during a test iteration, enable
     for subsequent iterations
   - Always-on: overhead of the hook when no concurrent work happens is minimal

5. **Interaction with pathTrie.** If schedule is part of the input, different
   schedules for the same data input produce different paths — which is exactly
   what we want. The path captures the interleaving, and pathTrie deduplicates
   by unique interleavings.

## Next steps

- Verify `swift_task_enqueueOnExecutor_hook` signature and behavior against
  Swift runtime source (look at `swift/stdlib/public/Concurrency/Task.cpp`)
- Prototype: install hook, buffer one GenericTimerPoller iteration, drain
  single-threaded with fixed schedule, verify deterministic coverage
- If prototype works: integrate schedule bytes into `Mutator` and corpus format
- Measure: does schedule-guided fuzzing find the subscribe callback edge (673)
  reliably? Compare time-to-coverage vs uncontrolled scheduling
