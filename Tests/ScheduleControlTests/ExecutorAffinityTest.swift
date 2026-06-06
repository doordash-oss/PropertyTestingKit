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

//  Regression guard for executor affinity under schedule control (review #40).
//
//  The scheduler captures jobs via the global task-enqueue hook and runs them via
//  `runSynchronously(on: sessionExecutor)`. Reading the code in isolation it looks
//  like EVERY job — including actor- and MainActor-isolated ones — is forced onto
//  the session (drain) thread, which would run main-thread-only code off the main
//  thread. In practice it does not: MainActor jobs enqueue on the MAIN executor,
//  not the global concurrent executor the hook intercepts, so they are never
//  captured and keep their main-thread affinity. Default actors that ARE captured
//  keep their (logical, not thread-bound) isolation because the session executor
//  is serial. This test pins that down so a future routing change can't silently
//  start hijacking MainActor work off the main thread.

import Foundation
import os
import Testing
@testable import ScheduleControl

@Suite("Executor affinity under schedule control", .serialized, .timeLimit(.minutes(1)))
struct ExecutorAffinityTest {

    /// MainActor work performed inside a scheduled run must still execute on the
    /// main thread. If the scheduler forces the MainActor job onto its session
    /// executor (drain thread), this observes a non-main thread.
    @Test("MainActor work runs on the main thread under schedule control")
    func mainActorRunsOnMainThread() async throws {
        let sawMainThread = OSAllocatedUnfairLock(initialState: false)
        let ran = OSAllocatedUnfairLock(initialState: false)

        try await ScheduleController.run(scheduleBytes: [0, 0, 0, 0, 0, 0, 0, 0]) {
            await MainActor.run {
                ran.withLock { $0 = true }
                sawMainThread.withLock { $0 = Thread.isMainThread }
            }
        }

        #expect(ran.withLock { $0 }, "the MainActor block must have run")
        #expect(sawMainThread.withLock { $0 },
                "MainActor work must run on the main thread even under schedule control")
    }
}
