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

private let _state = OSAllocatedUnfairLock(initialState: HookState())

private struct HookState: Sendable {
    var pending: [UnownedJob] = []
    var original: OriginalFn? = nil
}

private let _jobArrived = DispatchSemaphore(value: 0)

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
private let _routingHook: HookFn = { job, original in
    let jobPtr = unsafeBitCast(job, to: UnsafeRawPointer.self)
    let keyBits = _sessionKeyBits.withLock { $0 }

    _state.withLock { s in
        if s.original == nil { s.original = original }
    }

    // Method 1: current task's session task local
    if let sid = SessionTag.id {
        if let actor = schedule_read_actor_from_job(jobPtr) {
            schedule_actor_registry_register(actor, Int64(sid))
        }
        schedule_tls_set_session(Int64(sid))
        _state.withLock { $0.pending.append(job) }
        _jobArrived.signal()
        return
    }

    // Method 2: enqueued job's own task locals
    if keyBits != 0 {
        let sid = schedule_read_session_from_task(jobPtr, UnsafeRawPointer(bitPattern: keyBits))
        if sid >= 0 {
            schedule_tls_set_session(sid)
            _state.withLock { $0.pending.append(job) }
            _jobArrived.signal()
            return
        }
    }

    // Method 3: pthread TLS
    if schedule_tls_get_session() >= 0 {
        _state.withLock { $0.pending.append(job) }
        _jobArrived.signal()
        return
    }

    // No session — pass through
    original(job)
}

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

            _state.withLock { $0.pending.removeAll() }
            drainSemaphore()
            schedule_actor_registry_clear()

            let completion = TestCompletion()

            // Set the target context for edge recording — all edge hits
            // from the test body will write directly to this context.
            if let coverageContext {
                sancov_set_target_context(coverageContext)
            }

            // Install the routing hook
            _hookPtr.ptr.pointee = _routingHook
            defer {
                _hookPtr.ptr.pointee = nil
                sancov_set_target_context(nil)
            }

            // Launch test — Task {} inherits session task local
            Task {
                do {
                    try await test()
                } catch {
                    completion.setError(error)
                }
                completion.markCompleted()
                _jobArrived.signal()
            }

            // Synchronous drain on the calling cooperative thread.
            // Blocks this thread with semaphore waits — acceptable because
            // parallelism: 1 is enforced and the pool has nprocs threads.
            _jobArrived.wait()

            var byteIndex = 0
            var steps = 0

            while !completion.isCompleted && steps < maxDrainSteps {
                steps += 1

                let (count, original) = _state.withLock { ($0.pending.count, $0.original) }
                guard let original else { break }

                if count == 0 {
                    _ = _jobArrived.wait(timeout: .now() + 0.1)
                    continue
                }

                let choice: Int
                if byteIndex < scheduleBytes.count && count > 1 {
                    choice = Int(scheduleBytes[byteIndex]) % count
                    byteIndex += 1
                } else {
                    choice = 0
                }

                let job = _state.withLock { $0.pending.remove(at: choice) }
                original(job)
                waitForStateChange(completion: completion)
            }

            if let error = completion.error {
                throw error
            }
        }
    }

    private static func waitForStateChange(completion: TestCompletion) {
        while !completion.isCompleted {
            let count = _state.withLock { $0.pending.count }
            if count > 0 { return }
            _ = _jobArrived.wait(timeout: .now() + 0.1)
        }
    }

    private static func drainSemaphore() {
        while _jobArrived.wait(timeout: .now()) == .success {}
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
