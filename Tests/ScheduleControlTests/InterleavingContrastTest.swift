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

/// Shared race counter for the contrast body. A file-global (not a captured
/// local) so both concurrent lane closures can reference the non-copyable
/// `Atomic` directly. Reset at the start of each `body()` run.
fileprivate let raceCounter = Atomic<Int>(0)

private func logEntry(_ label: String) {
    entryLog.withLock { $0.append(label) }
}

@inline(never) private func workA0() -> Int { logEntry("A0"); var s = 0; for i in 0..<5 { s &+= i }; return s }
@inline(never) private func workA1() -> Int { logEntry("A1"); var s = 0; for i in 0..<6 { s &+= i*2 }; return s }
@inline(never) private func workA2() -> Int { logEntry("A2"); var s = 0; for i in 0..<7 { s &+= i*3 }; return s }
@inline(never) private func workB0() -> Int { logEntry("B0"); var s = 1; for i in 0..<5 { s &*= (i|1) }; return s }
@inline(never) private func workB1() -> Int { logEntry("B1"); var s = 1; for i in 0..<6 { s &*= (i|1)*2 }; return s }
@inline(never) private func workB2() -> Int { logEntry("B2"); var s = 1; for i in 0..<7 { s &*= (i|1)*3 }; return s }
@inline(never) private func workC0() -> Int { logEntry("C0"); var s = 2; for i in 0..<5 { s = s &+ (i ^ 0x5a) }; return s }
@inline(never) private func workC1() -> Int { logEntry("C1"); var s = 2; for i in 0..<6 { s = s &- (i ^ 0x33) }; return s }
@inline(never) private func workC2() -> Int { logEntry("C2"); var s = 2; for i in 0..<7 { s = s &+ (i &<< 2) }; return s }

/// CPU busy-work between edge hits. Spreads each lane's edge first-hits out over
/// wall-clock time so two lanes running in parallel genuinely interleave their
/// edge recording (rather than one lane finishing before the other starts).
@inline(never) private func spin(_ n: Int) -> Int {
    var s = 0
    for i in 0..<n { s = (s &+ i) &* 2_654_435_761 &+ (s &>> 3) }
    return s
}

@Suite("Interleaving Contrast", .serialized, .timeLimit(.minutes(1)))
struct InterleavingContrastTest {

    /// Two CPU-bound lanes that run in parallel (no cooperative yields), each
    /// spreading its edge first-hits across wall-clock time via `spin`. Without
    /// schedule control the two lanes race on real threads, so the order their
    /// edges first fire — and thus the recorded pathTrie path — varies run to run.
    /// Under schedule control the engine captures both lanes' jobs and dispatches
    /// them in a single, byte-determined order, collapsing that race to one path.
    private static func body() async {
        // Both lanes share an atomic counter and choose which edge to fire from
        // its current parity. Without schedule control the two lanes race on the
        // counter on real threads, so the increment interleaving — and thus which
        // edges fire in which order (the recorded pathTrie path) — varies run to
        // run. Under schedule control the engine serializes the lanes in a single
        // byte-determined order, so the counter sequence (and the path) is fixed.
        // `spin` between increments spreads them out so the race actually occurs
        // rather than one lane finishing its burst before the other starts.
        raceCounter.store(0, ordering: .relaxed)
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for _ in 0..<9 {
                    let v = raceCounter.add(1, ordering: .relaxed).newValue
                    switch v % 3 {
                    case 0: _ = workA0()
                    case 1: _ = workA1()
                    default: _ = workA2()
                    }
                    _ = spin(800)
                }
            }
            group.addTask {
                for _ in 0..<9 {
                    let v = raceCounter.add(1, ordering: .relaxed).newValue
                    switch v % 3 {
                    case 0: _ = workB0()
                    case 1: _ = workB1()
                    default: _ = workB2()
                    }
                    _ = spin(800)
                }
            }
            group.addTask {
                for _ in 0..<9 {
                    let v = raceCounter.add(1, ordering: .relaxed).newValue
                    switch v % 3 {
                    case 0: _ = workC0()
                    case 1: _ = workC1()
                    default: _ = workC2()
                    }
                    _ = spin(800)
                }
            }
        }
    }

    private static let scheduleBytes: [UInt8] = [
        42, 17, 255, 0, 100, 73, 99, 201, 3, 88, 150, 44, 12, 77, 233, 56,
        128, 64, 32, 16, 8, 4, 2, 1, 200, 100, 50, 25, 12, 6, 3, 1,
    ]

    @Test("UNCONTROLLED: OS scheduling produces more than one unique pathTrie path",
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
        // The contrast that matters: without schedule control the lanes race on
        // the shared counter on real threads, so coverage is NOT pinned to a
        // single path (controlledHasOnePath asserts the controlled run IS pinned
        // to exactly 1). The exact number of distinct interleavings the OS
        // produces is environment-dependent — a quiet, fast machine yields only a
        // couple — so we assert the robust property (> 1, i.e. nondeterministic)
        // rather than a brittle machine-tuned count.
        #expect(unique > 1, "Expected nondeterministic coverage (>1 path) without schedule control, got \(unique)")
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
