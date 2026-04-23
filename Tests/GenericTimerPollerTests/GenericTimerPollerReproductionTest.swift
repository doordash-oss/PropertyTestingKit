// Copyright 2026 DoorDash, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

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
