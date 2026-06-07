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

import Foundation
import Testing
import PropertyTestingKit

/// When several parallel engines run and one finds a counterexample (and halts
/// via a stop-on-failure plugin), the whole `fuzz` call should return as soon as
/// that first engine reports the failure — cancelling the siblings — rather than
/// waiting out the slowest engine's full time budget.
@Suite("Parallel early-cancel", .serialized)
struct ParallelEarlyCancelTest {
    struct Boom: Error {}

    @Test("first engine to find a counterexample cancels the rest")
    func cancelsSiblingsOnFirstFailure() async throws {
        // A value mutation of the small benign seeds will not stumble onto.
        let sentinel = 0x1F2E_3D4C_5B6A_79

        let stopOnFailure = FuzzPlugin<Int>(
            id: "stop_on_failure",
            handleSync: { _ in [] },
            handleAsync: { event in
                if case .failureFound = event {
                    return [.stop(FuzzPluginAction<Int>.StopAction(reason: .custom("found")))]
                }
                return []
            }
        )

        // Round-robin seed split (one share per engine): engine 0 gets `sentinel`
        // and fails on its first input; engines 1–3 mutate benign seeds and would
        // otherwise run the entire budget without ever failing.
        let budget = Duration.seconds(8)
        let start = ContinuousClock.now

        // `fuzz` reports the counterexample both by throwing and by recording a
        // Swift Testing issue; `withKnownIssue` absorbs both and also asserts that
        // a failure did occur.
        await withKnownIssue("seeded counterexample is reported") {
            _ = try await fuzz(
                seeds: [sentinel, 1, 2, 3],
                duration: budget,
                persistence: .ephemeral,
                parallelism: 4,
                plugins: { [.corpusMutation(), stopOnFailure] }
            ) { (x: Int) in
                if x == sentinel { throw Boom() }
            }
        }

        let elapsed = ContinuousClock.now - start

        #expect(
            elapsed < .seconds(3),
            "fuzz took \(elapsed) of an \(budget) budget — siblings were not cancelled on first failure"
        )
    }
}
