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

//
//  ParallelTimingTest.swift
//  PropertyTestingKit
//
//  Test to diagnose parallel fuzz timing/serialization issues.
//

import Foundation
import Testing
import PropertyTestingKit

@Suite("Parallel Timing Test", .serialized)  // Force sequential to isolate measurements
struct ParallelTimingTest {
    @Test("Single fuzz call with parallelism=16")
    func testSingleFuzzTiming() async throws {
        fputs("[TEST] Starting single fuzz() call with parallelism=16\n", stderr)
        let start = DispatchTime.now().uptimeNanoseconds

        let result = try await fuzz(
            duration: .milliseconds(100),
            corpusMode: .refuzzReplace,
            parallelism: 16  // Internal parallelism
        ) { (input: Int) in
            // Fast test - no work
        }

        let end = DispatchTime.now().uptimeNanoseconds
        let durationMs = (end - start) / 1_000_000
        fputs("[TEST] Single fuzz() completed in \(durationMs)ms with \(result.stats.totalInputs) iterations\n", stderr)
    }

    @Test("16 parallel fuzz calls with parallelism=16 each")
    func test16ParallelFuzzTiming() async throws {
        fputs("[TEST] Starting 16 parallel fuzz() calls, each with parallelism=16 (256 total engines)\n", stderr)
        let start = DispatchTime.now().uptimeNanoseconds

        let totalIterations = await withTaskGroup(of: Int.self, returning: Int.self) { group in
            for i in 0..<16 {
                group.addTask {
                    let taskStart = DispatchTime.now().uptimeNanoseconds
                    fputs("[TEST] Task \(i) starting fuzz() at \(taskStart / 1_000_000)ms\n", stderr)

                    let result = try? await fuzz(
                        duration: .milliseconds(100),
                        corpusMode: .refuzzReplace,
                        parallelism: 16  // Internal parallelism - 256 total engines!
                    ) { (input: Int) in
                        // Fast test - no work
                    }

                    let taskEnd = DispatchTime.now().uptimeNanoseconds
                    fputs("[TEST] Task \(i) finished fuzz() at \(taskEnd / 1_000_000)ms (took \((taskEnd - taskStart) / 1_000_000)ms)\n", stderr)

                    return result?.stats.totalInputs ?? 0
                }
            }
            return await group.reduce(0, +)
        }

        let end = DispatchTime.now().uptimeNanoseconds
        let durationMs = (end - start) / 1_000_000
        fputs("[TEST] All 16 tasks completed in \(durationMs)ms, total iterations: \(totalIterations)\n", stderr)
    }
}
