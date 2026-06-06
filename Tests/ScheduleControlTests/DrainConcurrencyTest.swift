import Testing
import Foundation
import os
@testable import ScheduleControl

/// Minimal test to determine if the drain loop allows concurrent job execution.
@Suite("Drain Loop Concurrency", .serialized, .timeLimit(.minutes(1)))
struct DrainConcurrencyTest {

    final class SharedState: Sendable {
        let aRunning = OSAllocatedUnfairLock(initialState: false)
        let overlapDetected = OSAllocatedUnfairLock(initialState: false)
        let aThread = OSAllocatedUnfairLock(initialState: UInt64(0))
        let bThread = OSAllocatedUnfairLock(initialState: UInt64(0))
    }

    @Test("Drain loop executes jobs serially without overlap")
    func jobsDoNotOverlap() async throws {
        let state = SharedState()

        try await ScheduleController.run(
            scheduleBytes: [0, 0, 0, 0, 0, 0, 0, 0]
        ) {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    state.aThread.withLock { pthread_threadid_np(nil, &$0) }

                    state.aRunning.withLock { $0 = true }
                    // Busy work to stay "running"
                    var sum = 0
                    for i in 0..<10_000 {
                        sum += i
                    }
                    _ = sum
                    state.aRunning.withLock { $0 = false }
                }
                group.addTask {
                    state.bThread.withLock { pthread_threadid_np(nil, &$0) }

                    let aStillRunning = state.aRunning.withLock { $0 }
                    if aStillRunning {
                        state.overlapDetected.withLock { $0 = true }
                    }
                }
            }
        }

        let didOverlap = state.overlapDetected.withLock { $0 }
        let tA = state.aThread.withLock { $0 }
        let tB = state.bThread.withLock { $0 }
        let sameThread = tA == tB && tA != 0

        print("Thread A: \(tA), Thread B: \(tB), same=\(sameThread)")
        print("Overlap detected: \(didOverlap)")

        #expect(!didOverlap, "Jobs should not overlap — drain loop must execute one at a time")
    }

    @Test("Task.yield inside session does not crash")
    func taskYieldInsideSession() async throws {
        try await ScheduleController.run(
            scheduleBytes: [0, 0, 0, 0, 0, 0, 0, 0]
        ) {
            // Task.yield() re-enqueues the current task. When run via
            // runSynchronously(on: _inlineExecutor), the runtime calls
            // _InlineExecutor.enqueue. This must not crash.
            await Task.yield()
        }
    }

    @Test("Detached Task.yield inside session does not crash")
    func detachedTaskYieldInsideSession() async throws {
        // This reproduces the megaYield pattern from swift-concurrency-extras.
        // A detached task has no task locals, so session routing falls through
        // to pthread TLS. If the drain loop thread has TLS set, the detached
        // task gets incorrectly captured.
        try await ScheduleController.run(
            scheduleBytes: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        ) {
            // Simulate megaYield: detached task that yields
            await Task.detached(priority: .background) {
                await Task.yield()
            }.value
        }
    }

    @Test("Many sessions run back-to-back and all complete")
    func manySequentialSessionsComplete() async throws {
        // Repeated session setup/teardown: each ScheduleController.run installs and
        // (LIFO-)restores the global hook and drains to completion. Running many in
        // a row guards that the install/restore + drain cycle is robust across
        // sessions and none stall.
        var completed = 0
        for _ in 0..<30 {
            try await ScheduleController.run(scheduleBytes: [0, 1, 0, 1, 0, 1, 0, 1]) {
                await withTaskGroup(of: Void.self) { inner in
                    inner.addTask { var s = 0; for i in 0..<50 { s += i }; _ = s }
                    inner.addTask { var s = 0; for i in 0..<50 { s += i }; _ = s }
                }
            }
            completed += 1
        }
        #expect(completed == 30, "all sessions should complete")
    }

    @Test("Two schedule-controlled sessions run in parallel without deadlock")
    func parallelSessionsBothComplete() async throws {
        let sessionADone = OSAllocatedUnfairLock(initialState: false)
        let sessionBDone = OSAllocatedUnfairLock(initialState: false)

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                try? await ScheduleController.run(
                    scheduleBytes: [0, 0, 0, 0, 0, 0, 0, 0]
                ) {
                    await withTaskGroup(of: Void.self) { inner in
                        inner.addTask { var s = 0; for i in 0..<100 { s += i }; _ = s }
                        inner.addTask { var s = 0; for i in 0..<100 { s += i }; _ = s }
                    }
                }
                sessionADone.withLock { $0 = true }
            }
            group.addTask {
                try? await ScheduleController.run(
                    scheduleBytes: [1, 1, 1, 1, 1, 1, 1, 1]
                ) {
                    await withTaskGroup(of: Void.self) { inner in
                        inner.addTask { var s = 0; for i in 0..<100 { s += i }; _ = s }
                        inner.addTask { var s = 0; for i in 0..<100 { s += i }; _ = s }
                    }
                }
                sessionBDone.withLock { $0 = true }
            }
        }

        let aDone = sessionADone.withLock { $0 }
        let bDone = sessionBDone.withLock { $0 }
        #expect(aDone, "Session A should complete")
        #expect(bDone, "Session B should complete")
    }
}
