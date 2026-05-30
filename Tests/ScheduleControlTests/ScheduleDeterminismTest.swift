import Testing
import Foundation
@testable import ScheduleControl
@testable import PropertyTestingKit

/// Verify that ScheduleController produces deterministic execution order
/// given the same schedule bytes.
@Suite("Schedule Determinism", .serialized)
struct ScheduleDeterminismTest {

    /// Simple actor that logs the order of method calls.
    actor OrderedActor {
        var log: [String] = []

        func record(_ entry: String) {
            log.append(entry)
        }

        func getLog() -> [String] {
            log
        }
    }

    /// Run a concurrent workload under schedule control and return the execution log.
    private func runWithSchedule(bytes: [UInt8]) async throws -> [String] {
        let actor = OrderedActor()

        try await ScheduleController.run(scheduleBytes: bytes) {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await actor.record("A1")
                    await actor.record("A2")
                    await actor.record("A3")
                }
                group.addTask {
                    await actor.record("B1")
                    await actor.record("B2")
                    await actor.record("B3")
                }
            }
        }

        return await actor.getLog()
    }

    @Test("Same schedule bytes produce same execution order")
    func determinism() async throws {
        let scheduleBytes: [UInt8] = [
            42, 17, 255, 0, 100, 73, 99, 201,
            3, 88, 150, 44, 12, 77, 233, 56,
            128, 64, 32, 16, 8, 4, 2, 1,
            200, 100, 50, 25, 12, 6, 3, 1,
        ]

        // Warmup: first call may differ due to cooperative pool initialization
        _ = try await runWithSchedule(bytes: scheduleBytes)

        // Run 5 times with the same bytes
        var logs: [[String]] = []
        for i in 0..<5 {
            let log = try await runWithSchedule(bytes: scheduleBytes)
            print("Run \(i): \(log)")
            logs.append(log)
        }

        // All runs should produce identical logs
        let first = logs[0]
        #expect(!first.isEmpty, "Expected some operations to be recorded")

        for (i, log) in logs.enumerated().dropFirst() {
            #expect(log == first, "Run \(i) differs from run 0: \(log) vs \(first)")
        }

        print("Deterministic order: \(first)")
    }

    @Test("Different schedule bytes can produce different execution order")
    func differentSchedulesDiffer() async throws {
        let bytes1: [UInt8] = Array(repeating: 0, count: 32) // always pick first
        let bytes2: [UInt8] = Array(repeating: 1, count: 32) // always pick second (when 2+ pending)

        let log1 = try await runWithSchedule(bytes: bytes1)
        let log2 = try await runWithSchedule(bytes: bytes2)

        print("Schedule [0...]: \(log1)")
        print("Schedule [1...]: \(log2)")

        #expect(!log1.isEmpty, "Expected operations with schedule [0...]")
        #expect(!log2.isEmpty, "Expected operations with schedule [1...]")

        // Both should contain all 6 entries
        #expect(Set(log1) == Set(["A1", "A2", "A3", "B1", "B2", "B3"]))
        #expect(Set(log2) == Set(["A1", "A2", "A3", "B1", "B2", "B3"]))

        // The whole point of schedule bytes: "always pick first" and "always
        // pick second" must produce different *interleavings*. Without this the
        // test passes even if scheduleBytes were ignored entirely.
        #expect(log1 != log2,
                "Different schedule bytes should produce different execution order: \(log1) vs \(log2)")
    }
}
