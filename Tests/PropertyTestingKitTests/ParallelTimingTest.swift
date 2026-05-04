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
    @Test("Single fuzz call with parallelism=16", .disabled())
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

    @Test("16 parallel fuzz calls with parallelism=16 each", .disabled())
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
