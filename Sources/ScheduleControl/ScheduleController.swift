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

/// Session-routing hook. Three methods to identify session ownership:
/// 1. Task local on enqueueing task (task creation, actor processing)
/// 2. Task local on enqueued job (parent re-enqueue during completeFuture)
/// 3. pthread TLS (ProcessOutOfLineJob during completeFuture)
/// Non-session jobs pass through via original(job).
/// Route a job to its session's queue, or pass through if no session.
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

    // Method 1: current task's session task local
    if let sid = SessionTag.id {
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
            schedule_tls_set_session(sid)
            routeToSession(Int(sid), job)
            return
        }
    }

    // Method 3: pthread TLS
    let tlsSid = schedule_tls_get_session()
    if tlsSid >= 0 {
        routeToSession(Int(tlsSid), job)
        return
    }

    // No session — pass through
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
