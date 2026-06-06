import Testing
import Foundation
import SanCovHooks
@testable import ScheduleControl
@testable import PropertyTestingKit

@Suite("Schedule Coverage", .serialized, .timeLimit(.minutes(1)))
struct ScheduleCoverageTest {

    /// Function with distinct branches, only called from scheduled test bodies.
    @inline(never)
    static func branchingCode(_ x: Int) -> Int {
        if x == 111 {
            return x * 3
        } else if x == 222 {
            return x / 2
        } else {
            return x + 1
        }
    }

    @Test("Engine sees different coverage for different branches under schedule control")
    func scheduledBranchCoverageDistinguishable() async throws {
        // Warmup cooperative pool
        try await ScheduleController.run(scheduleBytes: [0]) {
            let _ = Self.branchingCode(0)
        }

        // Run 1: hit branch x == 111
        let ctx1 = SanCovCounters.beginMeasurement()
        SanCovCounters.resetCoverage(ctx1)

        try await ScheduleController.run(scheduleBytes: [0], coverageContext: ctx1.rawContext) {
            let _ = Self.branchingCode(111)
        }

        let edges1 = try SanCovCounters.snapshotCoveredArrays(with: ctx1)
        SanCovCounters.endMeasurement(ctx1)

        // Run 2: hit branch x == 222
        let ctx2 = SanCovCounters.beginMeasurement()
        SanCovCounters.resetCoverage(ctx2)

        try await ScheduleController.run(scheduleBytes: [0], coverageContext: ctx2.rawContext) {
            let _ = Self.branchingCode(222)
        }

        let edges2 = try SanCovCounters.snapshotCoveredArrays(with: ctx2)
        SanCovCounters.endMeasurement(ctx2)

        // Run 3: empty body (setup-only baseline)
        let ctx3 = SanCovCounters.beginMeasurement()
        SanCovCounters.resetCoverage(ctx3)

        try await ScheduleController.run(scheduleBytes: [0], coverageContext: ctx3.rawContext) {
            // no test code
        }

        let edges3 = try SanCovCounters.snapshotCoveredArrays(with: ctx3)
        SanCovCounters.endMeasurement(ctx3)

        let set1 = Set(edges1.indices)
        let set2 = Set(edges2.indices)
        let setup = Set(edges3.indices)

        let shared = set1.intersection(set2)
        let only1 = set1.subtracting(set2)
        let only2 = set2.subtracting(set1)

        print("Branch 111: \(set1.sorted())")
        print("Branch 222: \(set2.sorted())")
        print("Empty body: \(setup.sorted())")
        print("Shared between 111 & 222: \(shared.sorted())")
        print("Only in 111: \(only1.sorted())")
        print("Only in 222: \(only2.sorted())")

        // If edges come from branchingCode:
        //   - Shared edges exist (function entry, first `if` check)
        //   - Each run has unique edges (the taken branch)
        // If edges come from setup only:
        //   - Zero shared edges (each beginMeasurement cycle is unique)
        //   - All edges are "unique" but actually from setup infrastructure

        #expect(!shared.isEmpty,
                "Runs must share common edges from branchingCode. Zero shared = coverage from setup only.")
    }

    @Test("Infrastructure edges are consistent and separate from test body edges")
    func infrastructureEdgesIdentified() async throws {
        // Warmup
        try await ScheduleController.run(scheduleBytes: [0]) {
            let _ = Self.branchingCode(0)
        }

        // Direct call (no schedule control) — baseline for branchingCode edges
        let ctxDirect = SanCovCounters.beginMeasurement()
        SanCovCounters.resetCoverage(ctxDirect)
        let _ = Self.branchingCode(111)
        let directEdges = Set((try SanCovCounters.snapshotCoveredArrays(with: ctxDirect)).indices)
        SanCovCounters.endMeasurement(ctxDirect)

        // Same call under schedule control
        let ctxSched = SanCovCounters.beginMeasurement()
        SanCovCounters.resetCoverage(ctxSched)
        try await ScheduleController.run(scheduleBytes: [0], coverageContext: ctxSched.rawContext) {
            let _ = Self.branchingCode(111)
        }
        let schedEdges = Set((try SanCovCounters.snapshotCoveredArrays(with: ctxSched)).indices)
        SanCovCounters.endMeasurement(ctxSched)

        // Empty body — infrastructure only
        let ctxEmpty = SanCovCounters.beginMeasurement()
        SanCovCounters.resetCoverage(ctxEmpty)
        try await ScheduleController.run(scheduleBytes: [0], coverageContext: ctxEmpty.rawContext) {
            // empty
        }
        let infraEdges = Set((try SanCovCounters.snapshotCoveredArrays(with: ctxEmpty)).indices)
        SanCovCounters.endMeasurement(ctxEmpty)

        // The test body edges = scheduled edges minus infrastructure
        let testBodyEdges = schedEdges.subtracting(infraEdges)
        // Direct edges should be a subset of test body edges
        let directInTestBody = directEdges.intersection(testBodyEdges)

        print("Direct call (no schedule): \(directEdges.sorted())")
        print("Scheduled call: \(schedEdges.sorted())")
        print("Infrastructure only: \(infraEdges.sorted())")
        print("Test body (sched - infra): \(testBodyEdges.sorted())")
        print("Direct edges found in test body: \(directInTestBody.sorted())")

        // Direct edges should appear in the scheduled test body edges
        #expect(directEdges.isSubset(of: schedEdges),
                "Direct call edges must appear in scheduled edges")
        #expect(!testBodyEdges.isEmpty,
                "Test body must contribute edges beyond infrastructure")
    }

    @Test("pathTrie advances under g_target_context (schedule control)")
    func trieAdvancesUnderTargetContext() async throws {
        // Warmup
        try await ScheduleController.run(scheduleBytes: [0]) {
            let _ = Self.branchingCode(0)
        }

        let trie = PathTrie()
        let ctx = SanCovCounters.beginMeasurement()
        SanCovCounters.attachTrie(trie, to: ctx)
        SanCovCounters.resetCoverage(ctx)

        // Run branchingCode(111) under schedule control with g_target_context
        try await ScheduleController.run(scheduleBytes: [0], coverageContext: ctx.rawContext) {
            let _ = Self.branchingCode(111)
        }

        let isNovel = trie.isUniquePath
        print("After branchingCode(111): isUniquePath=\(isNovel)")

        SanCovCounters.endMeasurement(ctx)

        // The trie must have advanced from root — g_target_context routes edges
        // to the measurement context, and the trie hook records them.
        // Without this fix, tls_cached_measurement_context would be NULL and
        // the trie would never advance (isUniquePath would always be false).
        #expect(isNovel, "Trie must advance under g_target_context — edges must reach the trie")
    }
}
