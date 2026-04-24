//
//  InterleavingContrastTest.swift
//  Demonstrates: without schedule control, concurrent non-actor tasks
//  produce many unique pathTrie paths. With schedule control, they
//  produce few (ideally one).
//

import Foundation
@testable import ScheduleControl
@testable import PropertyTestingKit
import SanCovHooks
import Testing

@inline(never)
private func workA(_ n: Int) -> Int {
    var s = 0
    for i in 0..<n { s &+= i }
    return s
}

@inline(never)
private func workB(_ n: Int) -> Int {
    var s = 1
    for i in 0..<n { s &*= (i | 1) }
    return s
}

@Suite("Interleaving Contrast", .serialized)
struct InterleavingContrastTest {

    private static func body() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = workA(3)
                await Task.yield()
                _ = workA(4)
                await Task.yield()
                _ = workA(5)
            }
            group.addTask {
                _ = workB(3)
                await Task.yield()
                _ = workB(4)
                await Task.yield()
                _ = workB(5)
            }
        }
    }

    private static let scheduleBytes: [UInt8] = [
        42, 17, 255, 0, 100, 73, 99, 201,
        3, 88, 150, 44, 12, 77, 233, 56,
        128, 64, 32, 16, 8, 4, 2, 1,
        200, 100, 50, 25, 12, 6, 3, 1,
    ]

    @Test("UNCONTROLLED: OS scheduling produces many unique pathTrie paths",
          .timeLimit(.minutes(1)))
    func uncontrolledHasManyPaths() async throws {
        await Self.body()

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
        // Apply compiler-generated edge filter — same as the production fuzz
        // API does. The filter removes TQ/TY async resume edges whose
        // first-hit order is influenced by continuation enqueue races that
        // ScheduleController doesn't observe.
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
