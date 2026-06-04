import Foundation
import os
import CScheduleHooks
import SanCovHooks

// MARK: - Hook types and globals

private typealias OriginalFn = @convention(thin) (UnownedJob) -> Void
private typealias HookFn = @convention(thin) (UnownedJob, OriginalFn) -> Void

private let _hookPtr = SendablePointer(resolveEnqueueHookPointer())

private func resolveEnqueueHookPointer() -> UnsafeMutablePointer<HookFn?> {
    guard let symbol = dlsym(dlopen(nil, 0), "swift_task_enqueueGlobal_hook") else {
        fatalError("swift_task_enqueueGlobal_hook not found in the Swift runtime — schedule control requires a runtime exposing this hook.")
    }
    return symbol.assumingMemoryBound(to: Optional<HookFn>.self)
}

/// Per-session state for the drain loop.
final class SessionState: @unchecked Sendable {
    /// This session's id. Stamped into pthread TLS during `dispatch` so
    /// that any runtime-internal enqueue (`ProcessOutOfLineJob` during
    /// `completeFuture`, etc.) that happens synchronously inside the
    /// dispatched job can be caught by method 3.
    let sid: Int

    let lock = OSAllocatedUnfairLock(initialState: [UnownedJob]())
    let jobArrived = DispatchSemaphore(value: 0)

    /// Per-session executor. When a job yields during `runSynchronously`,
    /// the runtime calls this executor's `enqueue` to reschedule the
    /// continuation back into this session's pending queue.
    private lazy var executor: _SessionExecutor = _SessionExecutor(session: self)

    /// Per-session coverage context. Set on the drain loop thread via TLS
    /// so parallel sessions don't corrupt each other's coverage.
    var coverageContext: UnsafeMutablePointer<SanCovMeasurementContext>?

    private let _dispatchCount = OSAllocatedUnfairLock(initialState: 0)
    /// Number of jobs this session's drain loop has dispatched.
    var dispatchCount: Int { _dispatchCount.withLock { $0 } }

    private let _method3AppendCount = OSAllocatedUnfairLock(initialState: 0)
    /// Number of jobs appended to this session's queue via method 3
    /// (pthread-TLS routing).
    var method3AppendCount: Int { _method3AppendCount.withLock { $0 } }

    init(sid: Int) {
        self.sid = sid
    }

    func append(_ job: UnownedJob) {
        lock.withLock { $0.append(job) }
        jobArrived.signal()
    }

    func appendFromMethod3(_ job: UnownedJob) {
        _method3AppendCount.withLock { $0 += 1 }
        append(job)
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
    /// Also stamps pthread TLS with this session's sid for the duration
    /// of `runSynchronously`, so method 3 in the routing hook can route
    /// runtime-internal enqueues (which fire on the same thread during
    /// the dispatched job) back to this session.
    func dispatch(_ job: UnownedJob) {
        _dispatchCount.withLock { $0 += 1 }
        let ctx = coverageContext
        if let ctx {
            sancov_set_target_context(ctx)
        }
        schedule_tls_set_session(Int64(sid))
        job.runSynchronously(on: executor.asUnownedSerialExecutor())
        schedule_tls_set_session(-1)
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

/// The enqueue hook that was installed before the first active session. Saved when
/// the session count goes 0 → 1 and restored when it returns to 0, so a foreign
/// hook installed by another component is preserved (LIFO) rather than clobbered
/// and cleared. Accessed only inside the `_sessions` critical section.
private let _savedHook = OSAllocatedUnfairLock<HookFn?>(initialState: nil)

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
    private static let _method3StaleSid = OSAllocatedUnfairLock(initialState: 0)
    private static let _passThrough = OSAllocatedUnfairLock(initialState: 0)
    private static let _method1JobKind = OSAllocatedUnfairLock(initialState: [Int: Int]())
    private static let _method2JobKind = OSAllocatedUnfairLock(initialState: [Int: Int]())
    private static let _method3JobKind = OSAllocatedUnfairLock(initialState: [Int: Int]())
    private static let _passThroughJobKind = OSAllocatedUnfairLock(initialState: [Int: Int]())

    /// Whether the routing hook records per-branch counters. Off by default so the
    /// process-global hook does no per-enqueue counter work in production; `reset()`
    /// turns it on (tests call `reset()` before reading the counters).
    private static let _counting = OSAllocatedUnfairLock(initialState: false)
    static var isCounting: Bool { _counting.withLock { $0 } }

    public static var method1Hits: Int { _method1.withLock { $0 } }
    public static var method2Hits: Int { _method2.withLock { $0 } }
    public static var method3Hits: Int { _method3.withLock { $0 } }
    /// Method-3 hits where the TLS sid was not in `_sessions`.
    public static var method3StaleSidHits: Int { _method3StaleSid.withLock { $0 } }
    public static var passThroughHits: Int { _passThrough.withLock { $0 } }
    public static var method1JobKinds: [Int: Int] { _method1JobKind.withLock { $0 } }
    public static var method2JobKinds: [Int: Int] { _method2JobKind.withLock { $0 } }
    public static var method3JobKinds: [Int: Int] { _method3JobKind.withLock { $0 } }
    public static var passThroughJobKinds: [Int: Int] { _passThroughJobKind.withLock { $0 } }

    public static func reset() {
        _counting.withLock { $0 = true }
        _method1.withLock { $0 = 0 }
        _method2.withLock { $0 = 0 }
        _method3.withLock { $0 = 0 }
        _method3StaleSid.withLock { $0 = 0 }
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
    static func recordMethod3StaleSid() {
        _method3StaleSid.withLock { $0 += 1 }
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
///
/// 1. Current task's `SessionTag.id` task-local.
///    Fires when the enqueueing task has the tag visible (e.g., the
///    initial `Task { test() }` spawn, `TaskGroup.addTask` from a
///    tagged parent).
///
/// 2. Session key on the enqueued job's own task-local chain.
///    Fires when the enqueueing context lacks `SessionTag.id` but the
///    enqueued job is an `AsyncTask` whose own local-storage chain
///    still carries the session tag (e.g., libdispatch timer threads
///    waking a `Task.sleep`).
///
/// 3. pthread TLS session ID.
///    Fires when neither method 1 nor method 2 matches but the current
///    pthread has a session ID stored in TLS by `SessionState.dispatch`.
///    TLS is set at the start of `runSynchronously` and cleared after,
///    so it is only present *while a session's job is currently
///    executing on this thread*. The intended case is
///    `ProcessOutOfLineJob` enqueued by runtime internals during
///    `completeFuture`, which fires synchronously inside the dispatched
///    job. Because TLS is scoped to dispatch, foreign work that runs
///    on the same thread *after* dispatch returns sees no stamp and
///    passes through cleanly.
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

    // Counters are test-only; skip the per-enqueue job-kind read and recording
    // entirely in production (when counting is disabled).
    let counting = RoutingHookCounters.isCounting
    let kind = counting ? readJobKind(jobPtr) : 0

    // Method 1: current task's session task local. Routes only — does
    // not stamp TLS (TLS is owned by `SessionState.dispatch`).
    if let sid = SessionTag.id {
        if counting { RoutingHookCounters.recordMethod1(jobKind: kind) }
        routeToSession(sid, job)
        return
    }

    // Method 2: enqueued job's own task locals. Routes only — does not
    // stamp TLS, same reason as method 1.
    if keyBits != 0 {
        let sid = schedule_read_session_from_task(jobPtr, UnsafeRawPointer(bitPattern: keyBits))
        if sid >= 0 {
            if counting { RoutingHookCounters.recordMethod2(jobKind: kind) }
            routeToSession(Int(sid), job)
            return
        }
    }

    // Method 3: pthread TLS. Only matches when an enqueue happens
    // synchronously inside `SessionState.dispatch`, since dispatch is
    // the only code path that sets TLS.
    let tlsSid = schedule_tls_get_session()
    if tlsSid >= 0 {
        if counting { RoutingHookCounters.recordMethod3(jobKind: kind) }
        if let session = _sessions.withLock({ $0[Int(tlsSid)] }) {
            session.appendFromMethod3(job)
            return
        }
        // Stale sid: session gone, pass through. Should be rare under
        // the new TLS-scope policy since dispatch always clears TLS.
        if counting { RoutingHookCounters.recordMethod3StaleSid() }
        if let original = _original.withLock({ $0 }) {
            original(job)
        }
        return
    }

    // No session — pass through
    if counting { RoutingHookCounters.recordPassThrough(jobKind: kind) }
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

// MARK: - Errors

/// Errors thrown by `ScheduleController.run`.
public enum ScheduleControlError: Error, CustomStringConvertible {
    /// The drain loop processed `limit` jobs without the test completing,
    /// indicating a probable deadlock or runaway enqueue.
    case drainStepLimitExceeded(Int)

    public var description: String {
        switch self {
        case .drainStepLimitExceeded(let limit):
            return "Schedule drain loop exceeded \(limit) steps without completing — possible deadlock or runaway enqueue."
        }
    }
}

// MARK: - ScheduleController

/// Controls Swift concurrency task scheduling order during fuzz testing.
///
/// Uses `swift_task_enqueueGlobal_hook` with session-based routing to
/// selectively capture jobs belonging to a specific session while passing
/// through all other jobs untouched.
public enum ScheduleController {

    private static let maxDrainSteps = 100_000

    /// Pure schedule-decision used by the drain loop: given the schedule bytes, the
    /// current read position, and how many jobs are pending, return which pending
    /// job to run next and the advanced read position.
    ///
    /// Exactly one byte is consumed per decision, so the byte at position *k* always
    /// governs the *k*-th dispatched job — independent of how many jobs happen to be
    /// queued at that instant. This keeps replay deterministic: byte position tracks
    /// the (stable) dispatch ordinal rather than the (timing-dependent) queue depth.
    /// When the bytes are exhausted the decision defaults to FIFO (index 0) without
    /// advancing. `pendingCount` must be >= 1 (the drain loop only decides when the
    /// queue is non-empty).
    static func scheduleChoice(
        scheduleBytes: [UInt8], byteIndex: Int, pendingCount: Int
    ) -> (choice: Int, nextByteIndex: Int) {
        guard byteIndex < scheduleBytes.count else { return (0, byteIndex) }
        return (Int(scheduleBytes[byteIndex]) % pendingCount, byteIndex + 1)
    }

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
        await runABISelfTestOnce()

        let sessionID = Int.random(in: 1..<Int.max)

        try await SessionTag.$id.withValue(sessionID) {
            captureSessionKeyIfNeeded()

            // Create per-session state
            let session = SessionState(sid: sessionID)

            let completion = TestCompletion()

            // Store coverage context on the session — dispatch() will set
            // the thread-local g_target_context on the serial queue thread.
            session.coverageContext = coverageContext

            // Register the session and install the routing hook under the same lock
            // that tears it down, so concurrent sessions install/restore the global
            // hook exactly once. The first session (0 → 1) saves whatever hook was
            // already installed; teardown restores it. Non-session jobs pass through
            // via original(job).
            _sessions.withLock { sessions in
                if sessions.isEmpty {
                    _savedHook.withLock { $0 = _hookPtr.ptr.pointee }
                    _hookPtr.ptr.pointee = _routingHook
                }
                sessions[sessionID] = session
            }

            // Launch test — Task {} inherits session task local
            let testTask = Task {
                do {
                    try await test()
                } catch {
                    completion.setError(error)
                }
                completion.markCompleted()
                session.jobArrived.signal()
            }

            // Drain loop on cooperative pool thread.
            //
            // The loop BLOCKS (DispatchSemaphore) rather than `await`s job
            // arrival, and this is deliberate — not a candidate for async
            // signalling. The drain thread is the one thread on which this
            // session's jobs run, via `dispatch` → `runSynchronously`. If the
            // loop awaited instead of blocking, it would suspend back into the
            // cooperative pool, and the runtime could then schedule THIS
            // session's own continuation jobs onto the freed thread out from
            // under the scheduler — defeating the single-threaded, byte-driven
            // dispatch order that is the whole point of schedule control. Owning
            // (blocking) the thread for the session's lifetime is what keeps
            // dispatch deterministic. The semaphore is signalled on every state
            // change (`append`, completion), so the only non-event wakeups are
            // the bounded `.now() + 0.1` fallbacks below, which exist purely as a
            // liveness backstop against a missed signal — not a busy-poll.
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

                let decision = ScheduleController.scheduleChoice(
                    scheduleBytes: scheduleBytes, byteIndex: byteIndex, pendingCount: count
                )
                byteIndex = decision.nextByteIndex

                let job = session.remove(at: decision.choice)
                session.dispatch(job)
                waitForStateChange(session: session, completion: completion)
            }

            let drainCompleted = completion.isCompleted

            _sessions.withLock { sessions in
                sessions[sessionID] = nil
                if sessions.isEmpty {
                    // Restore the hook that was installed before the first session
                    // rather than unconditionally clearing it.
                    _hookPtr.ptr.pointee = _savedHook.withLock { $0 }
                }
            }

            if !drainCompleted {
                // The drain loop hit `maxDrainSteps` without the test finishing —
                // likely a deadlock or runaway enqueue. Cancel the orphaned test
                // task and surface the failure rather than reporting false success.
                testTask.cancel()
                throw ScheduleControlError.drainStepLimitExceeded(maxDrainSteps)
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

    /// Internal helper for tests: returns the SessionState for the current
    /// session tag. `nil` if called outside a session body or after teardown.
    static func _currentSessionStateForTesting() -> SessionState? {
        guard let sid = SessionTag.id else { return nil }
        return _sessions.withLock { $0[sid] }
    }

    /// Verifies that the private Swift-runtime ABI offsets the C reader depends on
    /// still hold: stamps a known value into the `SessionTag` task-local, then reads
    /// it back through the exact C path routing method 2 uses. Returns `false` if the
    /// value does not round-trip — a sign the Job/AsyncTask layout has drifted on
    /// this toolchain, in which case schedule control would silently stop capturing
    /// jobs. Cheap; run once at startup.
    static func verifyTaskLocalABI() async -> Bool {
        let sentinel: Int = 0x5E55_10AB
        return await SessionTag.$id.withValue(sentinel) {
            guard let task = _getCurrentTask() else { return false }
            guard let key = schedule_capture_session_key(task) else { return false }
            return schedule_read_session_from_task(task, key) == Int64(sentinel)
        }
    }

    /// One-time ABI self-test, run on the first `ScheduleController.run`. On failure
    /// it surfaces a loud diagnostic instead of letting schedule control degrade to
    /// a silent no-op (routing would read garbage / return -1 and pass every job
    /// through).
    private static let _abiChecked = OSAllocatedUnfairLock(initialState: false)
    private static func runABISelfTestOnce() async {
        let alreadyChecked = _abiChecked.withLock { done -> Bool in
            if done { return true }
            done = true
            return false
        }
        if alreadyChecked { return }
        if await !verifyTaskLocalABI() {
            FileHandle.standardError.write(Data(
                "[ScheduleControl] ABI self-test FAILED: the Swift-runtime task-local layout this build relies on appears to have changed. Schedule control will not reliably capture tasks — re-verify the offsets in CScheduleHooks/ScheduleHooks.c.\n"
                    .utf8))
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
