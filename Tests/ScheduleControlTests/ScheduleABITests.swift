import Testing
@testable import ScheduleControl

/// Guards the private Swift-runtime ABI offsets the C task-local reader depends on.
/// If the Job/AsyncTask layout drifts on a future toolchain, this round-trip fails,
/// catching the drift before schedule control silently degrades to a no-op.
@Suite("Schedule ABI Self-Check", .serialized, .timeLimit(.minutes(1)))
struct ScheduleABITests {

    @Test("Task-local ABI offsets round-trip a known session value")
    func taskLocalABIRoundTrips() async {
        #expect(
            await ScheduleController.verifyTaskLocalABI(),
            "C task-local reader must read back a known SessionTag value; failure indicates Swift-runtime ABI drift"
        )
    }
}
