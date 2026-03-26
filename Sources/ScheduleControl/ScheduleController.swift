import Foundation
import os

// MARK: - Hook types and globals

private typealias OriginalFn = @convention(thin) (UnownedJob) -> Void
private typealias HookFn = @convention(thin) (UnownedJob, OriginalFn) -> Void

/// Pointer to the global `swift_task_enqueueGlobal_hook` variable in the Swift runtime.
/// Sendable wrapper needed because `UnsafeMutablePointer` is not Sendable.
private let _hookPtr = SendablePointer(
    dlsym(dlopen(nil, 0), "swift_task_enqueueGlobal_hook")!
        .assumingMemoryBound(to: Optional<HookFn>.self)
)

/// Thread-safe state shared between the hook (pool threads) and drain loop (drain thread).
private let _state = OSAllocatedUnfairLock(initialState: HookState())

private struct HookState: Sendable {
    var pending: [UnownedJob] = []
    var original: OriginalFn? = nil
}

/// Signaled by the hook when a job is buffered, and by completion to unblock the drain loop.
private let _jobArrived = DispatchSemaphore(value: 0)

/// @convention(thin) cannot capture state, so this is module-level.
private let _bufferHook: HookFn = { job, original in
    _state.withLock {
        $0.pending.append(job)
        if $0.original == nil { $0.original = original }
    }
    _jobArrived.signal()
}

// MARK: - SendablePointer

/// Wrapper to make UnsafeMutablePointer Sendable for module-level storage.
/// Safety: the pointer targets a single global variable in the Swift runtime.
/// Access is serialized by the ScheduleController (one run at a time).
private struct SendablePointer: @unchecked Sendable {
    let ptr: UnsafeMutablePointer<HookFn?>
    init(_ ptr: UnsafeMutablePointer<HookFn?>) { self.ptr = ptr }
}

// MARK: - ScheduleController

/// Controls Swift concurrency task scheduling order during fuzz testing.
///
/// Uses `swift_task_enqueueGlobal_hook` to intercept task enqueue operations,
/// buffer them, and drain one-at-a-time in a fuzz-guided order determined by
/// `scheduleBytes`.
///
/// ## Execution model
///
/// The drain loop runs on a dedicated dispatch queue (NOT the cooperative pool)
/// to avoid blocking pool threads. Jobs are dispatched one at a time to the
/// cooperative pool via the saved `original` function. A semaphore synchronizes
/// between the drain loop and the hook — when a dispatched job suspends (and its
/// continuation or child tasks arrive via the hook), the semaphore is signaled,
/// waking the drain loop for the next scheduling decision.
///
/// Same schedule bytes + same input = same interleaving = same coverage path.
public enum ScheduleController {

    private static let maxDrainSteps = 100_000

    /// Dedicated serial queue for the drain loop. Not a cooperative pool thread,
    /// so blocking on semaphore is safe.
    private static let drainQueue = DispatchQueue(label: "schedule-control.drain")

    /// Execute `test` under schedule control.
    ///
    /// - Parameters:
    ///   - scheduleBytes: Bytes that guide scheduling decisions. When multiple
    ///     jobs are pending, `byte % pendingCount` selects which job runs next.
    ///   - test: The async throwing closure to execute under schedule control.
    public static func run(
        scheduleBytes: [UInt8],
        test: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            drainQueue.async {
                do {
                    try synchronousDrain(scheduleBytes: scheduleBytes, test: test)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// The synchronous drain loop. Runs on `drainQueue` (a plain dispatch queue),
    /// NOT on the cooperative thread pool.
    private static func synchronousDrain(
        scheduleBytes: [UInt8],
        test: @escaping @Sendable () async throws -> Void
    ) throws {
        // Clear stale state
        _state.withLock { $0.pending.removeAll() }
        drainSemaphore()

        let completion = TestCompletion()

        // Install the hook
        _hookPtr.ptr.pointee = _bufferHook
        defer { _hookPtr.ptr.pointee = nil }

        // Launch the test as a detached task. Task.detached goes through
        // swift_task_enqueueGlobal, so the hook captures it.
        Task.detached {
            do {
                try await test()
            } catch {
                completion.setError(error)
            }
            completion.markCompleted()
            _jobArrived.signal()
        }

        // Wait for the initial job to arrive
        _jobArrived.wait()

        var byteIndex = 0
        var steps = 0

        while !completion.isCompleted && steps < maxDrainSteps {
            steps += 1

            let (count, original) = _state.withLock { ($0.pending.count, $0.original) }
            guard let original else { break }

            if count == 0 {
                if _jobArrived.wait(timeout: .now() + 5.0) == .timedOut { break }
                continue
            }

            // Use schedule bytes to pick which job runs next
            let choice: Int
            if byteIndex < scheduleBytes.count && count > 1 {
                choice = Int(scheduleBytes[byteIndex]) % count
                byteIndex += 1
            } else {
                choice = 0
            }

            let job = _state.withLock { $0.pending.remove(at: choice) }

            // Dispatch to the cooperative pool via the original function.
            // The job runs on a pool thread until it suspends, at which point
            // the hook captures its continuation and signals the semaphore.
            original(job)

            // Wait for the dispatched job to produce observable state change:
            // either new jobs arrive in pending, or the test completes.
            // Polling with semaphore is more robust than counting signals,
            // which can accumulate from runtime infrastructure jobs.
            waitForStateChange(completion: completion)
        }

        if let error = completion.error {
            throw error
        }
    }

    /// Wait until either new pending jobs appear or the test completes.
    /// Uses the semaphore as a wakeup signal but verifies actual state change
    /// to avoid issues with spurious or accumulated signals.
    private static func waitForStateChange(completion: TestCompletion) {
        while !completion.isCompleted {
            let count = _state.withLock { $0.pending.count }
            if count > 0 { return }
            // Brief wait — semaphore is signaled by hook on every new job
            if _jobArrived.wait(timeout: .now() + 5.0) == .timedOut { return }
        }
    }

    private static func drainSemaphore() {
        while _jobArrived.wait(timeout: .now()) == .success {}
    }
}

// MARK: - TestCompletion

private final class TestCompletion: @unchecked Sendable {
    private let _lock = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var completed = false
        var error: (any Error)?
    }

    var isCompleted: Bool {
        _lock.withLock { $0.completed }
    }

    var error: (any Error)? {
        _lock.withLock { $0.error }
    }

    func markCompleted() {
        _lock.withLock { $0.completed = true }
    }

    func setError(_ error: any Error) {
        _lock.withLock { $0.error = error }
    }
}
