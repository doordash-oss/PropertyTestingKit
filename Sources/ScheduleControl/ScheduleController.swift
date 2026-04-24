import Foundation
import os
import CScheduleHooks
import SanCovHooks

// MARK: - Hook types and globals

private typealias OriginalFn = @convention(thin) (UnownedJob) -> Void
private typealias HookFn = @convention(thin) (UnownedJob, OriginalFn) -> Void

private let _hookPtr = SendablePointer(
    dlsym(dlopen(nil, 0), "swift_task_enqueueGlobal_hook")!
        .assumingMemoryBound(to: Optional<HookFn>.self)
)

/// Per-session state for the drain loop.
final class SessionState: @unchecked Sendable {
    let lock = OSAllocatedUnfairLock(initialState: [UnownedJob]())
    let jobArrived = DispatchSemaphore(value: 0)

    /// Per-session executor. When a job yields during `runSynchronously`,
    /// the runtime calls this executor's `enqueue` to reschedule the
    /// continuation back into this session's pending queue.
    private lazy var executor: _SessionExecutor = _SessionExecutor(session: self)

    /// Per-session coverage context. Set on the drain loop thread via TLS
    /// so parallel sessions don't corrupt each other's coverage.
    var coverageContext: UnsafeMutablePointer<SanCovMeasurementContext>?

    func append(_ job: UnownedJob) {
        lock.withLock { $0.append(job) }
        jobArrived.signal()
    }

    var count: Int {
        lock.withLock { $0.count }
    }

    func remove(at index: Int) -> UnownedJob {
        lock.withLock { $0.remove(at: index) }
    }

    /// Run a job segment synchronously on the current thread.
    /// Sets the thread-local g_target_context before running the job
    /// and clears it after, so parallel sessions are isolated.
    func dispatch(_ job: UnownedJob) {
        let ctx = coverageContext
        if let ctx {
            sancov_set_target_context(ctx)
        }
        job.runSynchronously(on: executor.asUnownedSerialExecutor())
        if ctx != nil {
            sancov_set_target_context(nil)
        }
    }
}

/// Per-session executor for `runSynchronously(on:)`.
///
/// When a job running via `runSynchronously` yields (e.g., `Task.yield()`),
/// the runtime calls `enqueue` on this executor to reschedule the continuation.
/// We route it back into the session's pending queue so the drain loop picks
/// it up on the next iteration.
private final class _SessionExecutor: SerialExecutor {
    let session: SessionState

    init(session: SessionState) {
        self.session = session
    }

    func enqueue(_ job: consuming ExecutorJob) {
        session.append(UnownedJob(job))
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }
}

/// Global registry of active sessions, keyed by session ID.
private let _sessions = OSAllocatedUnfairLock(initialState: [Int: SessionState]())

/// Original enqueue function, captured once from the first hook call.
private let _original = OSAllocatedUnfairLock<OriginalFn?>(initialState: nil)

/// Task-local key stored as UInt (pointer bits). 0 = not captured.
private let _sessionKeyBits = OSAllocatedUnfairLock<UInt>(initialState: 0)

private let _getCurrentTask: @convention(c) () -> UnsafeRawPointer? = {
    unsafeBitCast(
        dlsym(dlopen(nil, 0), "swift_task_getCurrent"),
        to: (@convention(c) () -> UnsafeRawPointer?).self
    )
}()

// MARK: - Routing hook

/// Per-branch hit counters for the routing hook. Exposed so tests can
/// verify that expected branches actually fire for specific code shapes.
public enum RoutingHookCounters {
    private static let _method1 = OSAllocatedUnfairLock(initialState: 0)
    private static let _method2 = OSAllocatedUnfairLock(initialState: 0)
    private static let _method3 = OSAllocatedUnfairLock(initialState: 0)
    private static let _passThrough = OSAllocatedUnfairLock(initialState: 0)
    private static let _method1JobKind = OSAllocatedUnfairLock(initialState: [Int: Int]())
    private static let _method2JobKind = OSAllocatedUnfairLock(initialState: [Int: Int]())
    private static let _method3JobKind = OSAllocatedUnfairLock(initialState: [Int: Int]())
    private static let _passThroughJobKind = OSAllocatedUnfairLock(initialState: [Int: Int]())

    public static var method1Hits: Int { _method1.withLock { $0 } }
    public static var method2Hits: Int { _method2.withLock { $0 } }
    public static var method3Hits: Int { _method3.withLock { $0 } }
    public static var passThroughHits: Int { _passThrough.withLock { $0 } }
    public static var method1JobKinds: [Int: Int] { _method1JobKind.withLock { $0 } }
    public static var method2JobKinds: [Int: Int] { _method2JobKind.withLock { $0 } }
    public static var method3JobKinds: [Int: Int] { _method3JobKind.withLock { $0 } }
    public static var passThroughJobKinds: [Int: Int] { _passThroughJobKind.withLock { $0 } }

    public static func reset() {
        _method1.withLock { $0 = 0 }
        _method2.withLock { $0 = 0 }
        _method3.withLock { $0 = 0 }
        _passThrough.withLock { $0 = 0 }
        _method1JobKind.withLock { $0 = [:] }
        _method2JobKind.withLock { $0 = [:] }
        _method3JobKind.withLock { $0 = [:] }
        _passThroughJobKind.withLock { $0 = [:] }
    }

    static func recordMethod1(jobKind: Int) {
        _method1.withLock { $0 += 1 }
        _method1JobKind.withLock { $0[jobKind, default: 0] += 1 }
    }
    static func recordMethod2(jobKind: Int) {
        _method2.withLock { $0 += 1 }
        _method2JobKind.withLock { $0[jobKind, default: 0] += 1 }
    }
    static func recordMethod3(jobKind: Int) {
        _method3.withLock { $0 += 1 }
        _method3JobKind.withLock { $0[jobKind, default: 0] += 1 }
    }
    static func recordPassThrough(jobKind: Int) {
        _passThrough.withLock { $0 += 1 }
        _passThroughJobKind.withLock { $0[jobKind, default: 0] += 1 }
    }
}

/// Read the job kind byte at offset 32 from the job pointer.
/// Matches `JOB_KIND_TASK=0`, `JOB_KIND_DEFAULT_ACTOR_INLINE=192`, etc.
private func readJobKind(_ jobPtr: UnsafeRawPointer) -> Int {
    let flagsPtr = jobPtr.advanced(by: 32).assumingMemoryBound(to: UInt32.self)
    return Int(flagsPtr.pointee & 0xFF)
}

/// Session-routing hook. Identification is attempted in priority order;
/// each enqueue takes exactly one path (early return per branch).
/// Empirical hit rates referenced below are from
/// `Tests/ScheduleControlTests/RoutingBranchTests.swift`.
///
/// 1. Current task's `SessionTag.id` task-local.
///    Fires when the enqueueing task has the tag visible. Observed
///    triggers include the initial `Task { test() }` spawn inside
///    `run`, `TaskGroup.addTask` from a tagged parent, `Task.detached`
///    from a tagged parent (the tag is read off the *spawning* task,
///    not the detached one), and a fraction of continuation re-enqueues
///    (roughly 1/3 in sequential yield tests — the rest take method 2).
///    Side effects: stamps pthread TLS and, for actor-processing jobs
///    (kinds 192–194), registers the actor pointer in the actor→session
///    registry.
///    NOTE: actor-processing job enqueues themselves are **not** reliably
///    caught here. In the actor-only test, the `ProcessOutOfLineJob`
///    enqueue landed in method 3, not method 1 — runtime internals
///    apparently enqueue the actor job from a context where the tag is
///    not visible.
///
/// 2. Session key on the enqueued job's own task-local chain.
///    Fires when the enqueueing context does not have `SessionTag.id`
///    visible but the job being enqueued is an `AsyncTask` whose own
///    local-storage chain still carries the session tag inherited from
///    its parent. This is the dominant path for continuation
///    re-enqueues: in a sequential `Task.yield()` loop it fires about
///    2× as often as method 1 (observed m2=22 vs m1=11 for 10 yields).
///
/// 3. pthread TLS session ID.
///    Fires when neither method 1 nor method 2 matches but the current
///    pthread has a session ID stored in TLS from a previous method-1
///    or method-2 routing. Observed to catch two kinds of jobs:
///    - `ProcessOutOfLineJob` for default-actor processing
///      (`JobKind` 192/193/194) enqueued by runtime internals during
///      `completeFuture`. This is the originally intended case.
///    - Untagged `AsyncTask` jobs (`JobKind` 0) enqueued on a
///      previously-stamped pool thread. Observed in every test that
///      involves concurrent child tasks (TaskGroup, detached) but
///      absent in sequential yield tests. Whose AsyncTasks these are
///      (runtime-internal vs framework vs our own children in a
///      setup-window gap) is not traced by the current tests.
///
/// Side effect shared by methods 1 and 2: `schedule_tls_set_session` is
/// called on every successful routing and is **never cleared**. This
/// stickiness is what makes method 3 work *within* a session, but also
/// means a pool thread retains session TLS after the session tears
/// down. If an unrelated test's job later runs on that thread, method 3
/// fires with a stale session ID; `routeToSession` then falls back to
/// `original(job)` because the session is gone from `_sessions`.
///
/// Non-session jobs (no method matches) pass through via `original(job)`.
/// Route a job to its session's queue, or fall back to `original(job)` if
/// the session ID is no longer registered (session torn down after
/// routing decided but before we reached here).
private func routeToSession(_ sid: Int, _ job: UnownedJob) {
    if let session = _sessions.withLock({ $0[sid] }) {
        session.append(job)
        return
    }
    // Session not found — use original to avoid dropping the job
    if let original = _original.withLock({ $0 }) {
        original(job)
    }
}

private let _routingHook: HookFn = { job, original in
    let jobPtr = unsafeBitCast(job, to: UnsafeRawPointer.self)
    let keyBits = _sessionKeyBits.withLock { $0 }

    _original.withLock { o in
        if o == nil { o = original }
    }

    let kind = readJobKind(jobPtr)

    // Method 1: current task's session task local
    if let sid = SessionTag.id {
        RoutingHookCounters.recordMethod1(jobKind: kind)
        if let actor = schedule_read_actor_from_job(jobPtr) {
            schedule_actor_registry_register(actor, Int64(sid))
        }
        schedule_tls_set_session(Int64(sid))
        routeToSession(sid, job)
        return
    }

    // Method 2: enqueued job's own task locals
    if keyBits != 0 {
        let sid = schedule_read_session_from_task(jobPtr, UnsafeRawPointer(bitPattern: keyBits))
        if sid >= 0 {
            RoutingHookCounters.recordMethod2(jobKind: kind)
            schedule_tls_set_session(sid)
            routeToSession(Int(sid), job)
            return
        }
    }

    // Method 3: pthread TLS
    let tlsSid = schedule_tls_get_session()
    if tlsSid >= 0 {
        RoutingHookCounters.recordMethod3(jobKind: kind)
        routeToSession(Int(tlsSid), job)
        return
    }

    // No session — pass through
    RoutingHookCounters.recordPassThrough(jobKind: kind)
    original(job)
}

// MARK: - Serial Job Executor

// (Serial execution is handled per-session via SessionState.executor)

// MARK: - Helpers

private struct SendablePointer: @unchecked Sendable {
    let ptr: UnsafeMutablePointer<HookFn?>
    init(_ ptr: UnsafeMutablePointer<HookFn?>) { self.ptr = ptr }
}

// MARK: - Session tag

/// Task-local session identifier for routing jobs to the correct scheduler session.
public enum SessionTag {
    @TaskLocal public static var id: Int?
}

// MARK: - ScheduleController

/// Controls Swift concurrency task scheduling order during fuzz testing.
///
/// Uses `swift_task_enqueueGlobal_hook` with session-based routing to
/// selectively capture jobs belonging to a specific session while passing
/// through all other jobs untouched.
public enum ScheduleController {

    private static let maxDrainSteps = 100_000

    /// Execute `test` under schedule control.
    ///
    /// - Parameters:
    ///   - scheduleBytes: Bytes that guide scheduling decisions.
    ///   - coverageContext: If non-nil, edge hits from the test body are recorded
    ///     directly to this context (bypassing task-keyed lookup). This enables
    ///     coverage-guided schedule fuzzing where the test runs in a different task.
    ///   - test: The async throwing closure to execute under schedule control.
    public static func run(
        scheduleBytes: [UInt8],
        coverageContext: UnsafeMutablePointer<SanCovMeasurementContext>? = nil,
        test: @escaping @Sendable () async throws -> Void
    ) async throws {
        schedule_tls_init()

        let sessionID = Int.random(in: 1..<Int.max)

        try await SessionTag.$id.withValue(sessionID) {
            captureSessionKeyIfNeeded()

            // Create per-session state
            let session = SessionState()
            _sessions.withLock { $0[sessionID] = session }

            schedule_actor_registry_clear()

            let completion = TestCompletion()

            // Store coverage context on the session — dispatch() will set
            // the thread-local g_target_context on the serial queue thread.
            session.coverageContext = coverageContext

            // Install the routing hook. Non-session jobs pass through via original(job).
            _hookPtr.ptr.pointee = _routingHook

            // Launch test — Task {} inherits session task local
            Task {
                do {
                    try await test()
                } catch {
                    completion.setError(error)
                }
                completion.markCompleted()
                session.jobArrived.signal()
            }

            // Drain loop on cooperative pool thread.
            session.jobArrived.wait()

            var byteIndex = 0
            var steps = 0

            while !completion.isCompleted && steps < maxDrainSteps {
                steps += 1

                let count = session.count

                if count == 0 {
                    _ = session.jobArrived.wait(timeout: .now() + 0.1)
                    continue
                }

                let choice: Int
                if byteIndex < scheduleBytes.count && count > 1 {
                    choice = Int(scheduleBytes[byteIndex]) % count
                    byteIndex += 1
                } else {
                    choice = 0
                }

                let job = session.remove(at: choice)
                session.dispatch(job)
                waitForStateChange(session: session, completion: completion)
            }

            _sessions.withLock { sessions in
                sessions[sessionID] = nil
                if sessions.isEmpty {
                    _hookPtr.ptr.pointee = nil
                }
            }

            if let error = completion.error {
                throw error
            }

            // Rebuild covered_indices from the bitmap now that drain is done
            // and no other thread is writing to the map. This is the single-threaded
            // fixup for not maintaining covered_indices during the concurrent drain.
            if let coverageContext {
                sancov_rebuild_covered_indices_from_map(coverageContext)
            }

        }
    }

    private static func waitForStateChange(session: SessionState, completion: TestCompletion) {
        while !completion.isCompleted {
            if session.count > 0 { return }
            _ = session.jobArrived.wait(timeout: .now() + 0.1)
        }
    }

    private static func captureSessionKeyIfNeeded() {
        let existing = _sessionKeyBits.withLock { $0 }
        if existing != 0 { return }
        if let task = _getCurrentTask() {
            if let key = schedule_capture_session_key(task) {
                let bits = UInt(bitPattern: key)
                _sessionKeyBits.withLock { $0 = bits }
            }
        }
    }
}

// MARK: - TestCompletion

private final class TestCompletion: @unchecked Sendable {
    private let _lock = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var completed = false
        var error: (any Error)?
    }

    var isCompleted: Bool { _lock.withLock { $0.completed } }
    var error: (any Error)? { _lock.withLock { $0.error } }
    func markCompleted() { _lock.withLock { $0.completed = true } }
    func setError(_ error: any Error) { _lock.withLock { $0.error = error } }
}
