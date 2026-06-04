//
//  InterleavingContrastTest.swift
//  Empirically measures whether concurrent non-actor Swift Tasks interleave
//  deterministically under OS scheduling.
//

import Foundation
import Synchronization
@testable import ScheduleControl
@testable import PropertyTestingKit
import SanCovHooks
import Testing

/// Log of task entries. Each call appends a marker showing which lane ran
/// and at what step within that lane.
fileprivate let entryLog = Mutex<[String]>([])

private func logEntry(_ label: String) {
    entryLog.withLock { $0.append(label) }
}

@inline(never) private func workA0() -> Int { logEntry("A0"); var s = 0; for i in 0..<5 { s &+= i }; return s }
@inline(never) private func workA1() -> Int { logEntry("A1"); var s = 0; for i in 0..<6 { s &+= i*2 }; return s }
@inline(never) private func workA2() -> Int { logEntry("A2"); var s = 0; for i in 0..<7 { s &+= i*3 }; return s }
@inline(never) private func workB0() -> Int { logEntry("B0"); var s = 1; for i in 0..<5 { s &*= (i|1) }; return s }
@inline(never) private func workB1() -> Int { logEntry("B1"); var s = 1; for i in 0..<6 { s &*= (i|1)*2 }; return s }
@inline(never) private func workB2() -> Int { logEntry("B2"); var s = 1; for i in 0..<7 { s &*= (i|1)*3 }; return s }

@Suite("Interleaving Contrast", .serialized, .timeLimit(.minutes(1)))
struct InterleavingContrastTest {

    private static func body() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = workA0()
                await Task.yield()
                _ = workA1()
                await Task.yield()
                _ = workA2()
            }
            group.addTask {
                _ = workB0()
                await Task.yield()
                _ = workB1()
                await Task.yield()
                _ = workB2()
            }
        }
    }

    private static let scheduleBytes: [UInt8] = [
        42, 17, 255, 0, 100, 73, 99, 201, 3, 88, 150, 44, 12, 77, 233, 56,
        128, 64, 32, 16, 8, 4, 2, 1, 200, 100, 50, 25, 12, 6, 3, 1,
    ]

    @Test("UNCONTROLLED: OS scheduling produces many unique pathTrie paths",
          .timeLimit(.minutes(1)))
    func uncontrolledHasManyPaths() async throws {
        // NOTE: We deliberately do not assert the global enqueue hook is nil.
        // That pointer is process-global and shared with any other suite that
        // may be mid-`ScheduleController.run`, so the check races. This test's
        // validity does not depend on it: with no SessionTag/TLS set, this
        // task's enqueues pass through `original` regardless of installation.
        SanCovCounters.applyEdgeFilter()

        let trie = PathTrie()
        let ctx = SanCovCounters.beginMeasurement()
        SanCovCounters.attachTrie(trie, to: ctx)
        defer { SanCovCounters.endMeasurement(ctx) }

        var unique = 0
        let iters = 500
        for _ in 0..<iters {
            SanCovCounters.resetCoverage(ctx)
            trie.reset()

            let ctxBits = UInt(bitPattern: ctx.rawContext)
            await CoverageInheritance.$context.withValue(ctxBits) {
                CoverageInheritance.captureKeyIfNeeded(contextBits: ctxBits)
                await Self.body()
            }

            if trie.isUniquePath { unique += 1; trie.markTerminal() }
        }
        print("UNCONTROLLED: \(unique) unique paths in \(iters) iterations")
        #expect(unique > 2, "Expected >2 unique paths without schedule control, got \(unique)")
    }

    @Test("CONTROLLED: schedule bytes pin the ordering to 1 unique path",
          .timeLimit(.minutes(1)))
    func controlledHasOnePath() async throws {
        SanCovCounters.applyEdgeFilter()

        try await ScheduleController.run(scheduleBytes: Self.scheduleBytes) {
            await Self.body()
        }

        let trie = PathTrie()
        let ctx = SanCovCounters.beginMeasurement()
        SanCovCounters.attachTrie(trie, to: ctx)
        defer { SanCovCounters.endMeasurement(ctx) }

        var unique = 0
        let iters = 200
        for _ in 0..<iters {
            SanCovCounters.resetCoverage(ctx)
            trie.reset()

            try await ScheduleController.run(
                scheduleBytes: Self.scheduleBytes,
                coverageContext: ctx.rawContext
            ) {
                await Self.body()
            }

            if trie.isUniquePath { unique += 1; trie.markTerminal() }
        }
        print("CONTROLLED: \(unique) unique paths in \(iters) iterations")
        #expect(unique == 1, "Expected 1 unique path under schedule control, got \(unique)")
    }

}
