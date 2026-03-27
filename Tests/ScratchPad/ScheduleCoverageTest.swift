import Testing
import Foundation
@testable import ScheduleControl
@testable import PropertyTestingKit

/// Test whether coverage from schedule-controlled code is visible to the
/// fuzz engine's measurement context.
@Suite("Schedule Coverage", .serialized)
struct ScheduleCoverageTest {

    @inline(never)
    static func exerciseBranches(_ value: Int) -> Int {
        if value > 10 {
            return value * 2
        } else {
            return value + 1
        }
    }

    actor CoverageActor {
        func compute(_ value: Int) -> Int {
            ScheduleCoverageTest.exerciseBranches(value)
        }
    }

    @Test("Baseline: coverage captured without schedule control")
    func baselineWithoutScheduleControl() async throws {
        let ctx = SanCovCounters.beginMeasurement()
        defer { SanCovCounters.endMeasurement(ctx) }
        SanCovCounters.resetCoverage(ctx)

        let _ = Self.exerciseBranches(42)

        let sparse = try SanCovCounters.snapshotCoveredArrays(with: ctx)
        print("Baseline (direct): \(sparse.indices.count) edges")
        #expect(sparse.indices.count > 0, "Direct call should produce coverage")
    }

    @Test("Schedule control: coverage from scheduled test visible to engine context")
    func scheduledCoverageCaptured() async throws {
        // Warmup
        try await ScheduleController.run(scheduleBytes: [0]) {
            let _ = Self.exerciseBranches(1)
        }

        let ctx = SanCovCounters.beginMeasurement()
        defer { SanCovCounters.endMeasurement(ctx) }
        SanCovCounters.resetCoverage(ctx)

        // Code runs in a DIFFERENT task (Task {} inside ScheduleController)
        try await ScheduleController.run(scheduleBytes: [0, 1, 0, 1]) {
            let _ = Self.exerciseBranches(42)
        }

        let sparse = try SanCovCounters.snapshotCoveredArrays(with: ctx)
        print("Scheduled: \(sparse.indices.count) edges")

        // CRITICAL: if 0, schedule fuzzing has no coverage feedback
        #expect(sparse.indices.count > 0,
                "Schedule-controlled code MUST produce coverage visible to engine context")
    }

    @Test("Schedule control with actor: coverage visible")
    func scheduledActorCoverage() async throws {
        let actor = CoverageActor()

        try await ScheduleController.run(scheduleBytes: [0]) {
            let _ = await actor.compute(1)
        }

        let ctx = SanCovCounters.beginMeasurement()
        defer { SanCovCounters.endMeasurement(ctx) }
        SanCovCounters.resetCoverage(ctx)

        try await ScheduleController.run(scheduleBytes: [0, 1, 0, 1]) {
            let _ = await actor.compute(42)
        }

        let sparse = try SanCovCounters.snapshotCoveredArrays(with: ctx)
        print("Scheduled (actor): \(sparse.indices.count) edges")
        #expect(sparse.indices.count > 0,
                "Actor code under schedule control MUST produce visible coverage")
    }

    @Test("Schedule control with TaskGroup: coverage visible")
    func scheduledTaskGroupCoverage() async throws {
        try await ScheduleController.run(scheduleBytes: [0]) {
            let _ = Self.exerciseBranches(1)
        }

        let ctx = SanCovCounters.beginMeasurement()
        defer { SanCovCounters.endMeasurement(ctx) }
        SanCovCounters.resetCoverage(ctx)

        try await ScheduleController.run(scheduleBytes: [0, 1, 0, 1]) {
            await withTaskGroup(of: Int.self) { group in
                group.addTask { Self.exerciseBranches(42) }
                group.addTask { Self.exerciseBranches(3) }
                for await _ in group {}
            }
        }

        let sparse = try SanCovCounters.snapshotCoveredArrays(with: ctx)
        print("Scheduled (TaskGroup): \(sparse.indices.count) edges")
        #expect(sparse.indices.count > 0,
                "TaskGroup code under schedule control MUST produce visible coverage")
    }
}
