//
//  GenericTimerPollerReproductionTest.swift
//  GenericTimerPollerTests
//
//  Regression test for a data race in a previous GenericTimerPoller implementation.
//
//  The original bug: `subscribe()` returned an `AnyCancellable` whose cancel
//  closure called actor-isolated `unsubscribe(_:)` directly — without `await`.
//  This bypassed actor isolation, causing concurrent Dictionary mutation when
//  cancel raced with subscribe.
//
//  The current implementation uses Task-based subscriptions where cancellation
//  goes through the actor properly. This test serves as a regression check.
//

import Clocks
import Dependencies
import GenericTimerPoller
import Testing

@Suite("GenericTimerPoller Reproduction")
struct GenericTimerPollerReproductionTests {

    /// Races subscribe and cancel to verify no data race on `handlers`.
    ///
    /// The previous implementation crashed here within ~50 iterations.
    @Test("Concurrent subscribe and cancel does not crash")
    func subscribeUnsubscribeRace() async throws {
        try await withDependencies {
            $0.continuousClock = ImmediateClock()
        } operation: {
            for _ in 0..<500 {
                let poller = GenericTimerPoller(defaultInterval: .microseconds(100))
                await poller.startPolling()

                let sub1 = await poller.subscribe { }
                let sub2 = await poller.subscribe { }

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
