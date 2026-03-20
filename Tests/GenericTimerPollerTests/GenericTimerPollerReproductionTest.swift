//
//  GenericTimerPollerReproductionTest.swift
//  GenericTimerPollerTests
//
//  Deterministic reproduction of a data race in GenericTimerPoller.
//
//  Bug: `subscribe()` returns an `AnyCancellable` whose cancel closure calls
//  actor-isolated `unsubscribe(_:)` directly — without `await`. In Swift 5 mode
//  this compiles as a warning, but at runtime the closure executes on whatever
//  thread calls `.cancel()`, bypassing actor isolation entirely.
//
//  When a cancel (→ unsubscribe → handlers[id] = nil) races with a subscribe
//  (→ handlers[id] = handler), both mutate the same Dictionary concurrently,
//  causing memory corruption (SIGSEGV / malloc double-free / EXC_BAD_ACCESS).
//
//  This test reliably reproduces the crash without any fuzzing framework.
//

import Clocks
@preconcurrency import Combine
import Dependencies
import GenericTimerPoller
import Testing

@Suite("GenericTimerPoller Reproduction")
struct GenericTimerPollerReproductionTests {

    /// Races subscribe and cancel to trigger the data race on `handlers`.
    ///
    /// Expected behavior: no crash.
    /// Actual behavior (unfixed): SIGSEGV or malloc abort within a few iterations.
    @Test("Data race: concurrent subscribe and cancel crashes")
    func subscribeUnsubscribeRace() async throws {
        try await withDependencies {
            $0.continuousClock = ImmediateClock()
        } operation: {
            // Repeat enough times that the race window is hit.
            // In practice the crash occurs within the first ~50 iterations.
            for _ in 0..<500 {
                let poller = GenericTimerPoller(defaultInterval: .microseconds(100))
                await poller.startPolling()

                // Accumulate cancellables that we'll cancel concurrently with new subscribes.
                let sub1 = await poller.subscribe { }
                let sub2 = await poller.subscribe { }

                // Task A: cancel existing subscriptions (fires AnyCancellable closure on this task's thread)
                // Task B: create new subscriptions (actor-isolated, mutates handlers on the actor)
                //
                // The bug: Task A's .cancel() calls unsubscribe() WITHOUT going through the actor,
                // so both tasks mutate `handlers` at the same time → data race.
                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        sub1.cancel()
                        sub2.cancel()
                    }
                    group.addTask {
                        _ = await poller.subscribe { }
                        _ = await poller.subscribe { }
                    }
                }

                await poller.stopPolling()
            }
        }
    }
}
