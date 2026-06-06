import Testing
@testable import ScheduleControl

/// Unit tests for the pure schedule-decision function that drives the drain loop.
/// One byte must be consumed per decision so the byte at position k governs the
/// k-th dispatched job regardless of transient queue depth (deterministic replay).
@Suite("Schedule Choice", .timeLimit(.minutes(1)))
struct ScheduleChoiceTests {

    @Test("Consumes one byte per decision even when only one job is pending")
    func consumesPerDecisionWithSinglePending() {
        // With a single pending job the choice is forced to 0, but a byte is still
        // consumed so the read position stays aligned to the dispatch ordinal.
        let (choice, next) = ScheduleController.scheduleChoice(
            scheduleBytes: [7, 9], byteIndex: 0, pendingCount: 1
        )
        #expect(choice == 0)
        #expect(next == 1, "a byte must be consumed even when pendingCount == 1")
    }

    @Test("Maps the byte to a pending index when there is a real choice")
    func mapsByteToIndex() {
        let (choice, next) = ScheduleController.scheduleChoice(
            scheduleBytes: [7, 9], byteIndex: 1, pendingCount: 4
        )
        #expect(choice == 9 % 4)
        #expect(next == 2)
    }

    @Test("Defaults to FIFO without advancing once bytes are exhausted")
    func fifoWhenExhausted() {
        let (choice, next) = ScheduleController.scheduleChoice(
            scheduleBytes: [7, 9], byteIndex: 2, pendingCount: 3
        )
        #expect(choice == 0)
        #expect(next == 2)
    }
}
