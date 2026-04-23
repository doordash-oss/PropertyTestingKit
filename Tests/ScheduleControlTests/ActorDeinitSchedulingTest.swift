import Testing
import Foundation
import Synchronization
@testable import ScheduleControl

/// Test whether an actor's deinit runs through the scheduler hook
/// (as an enqueued job) or inline on the deallocating thread.
@Suite("Actor Deinit Scheduling", .serialized)
struct ActorDeinitSchedulingTest {

    /// Simple actor that records when its deinit runs.
    actor TestActor {
        let onDeinit: @Sendable () -> Void

        init(onDeinit: @escaping @Sendable () -> Void) {
            self.onDeinit = onDeinit
        }

        deinit {
            onDeinit()
        }

        func doWork() {
            // Touch some state so the actor is actually used
        }
    }

    @Test("Actor deinit under schedule control is enqueued as a job")
    func actorDeinitIsScheduledJob() async throws {
        let deinitRan = Atomic<Bool>(false)
        let deinitRanDuringDrain = Atomic<Bool>(false)

        try await ScheduleController.run(
            scheduleBytes: [0, 0, 0, 0, 0, 0, 0, 0]
        ) {
            // Create actor, use it, then drop it
            var actor: TestActor? = TestActor(onDeinit: {
                deinitRan.store(true, ordering: .sequentiallyConsistent)
            })
            await actor!.doWork()
            actor = nil

            // If deinit ran inline (synchronously on this task),
            // it would be true here already.
            // If it's enqueued as a job, it runs later during drain.
            let ranInline = deinitRan.load(ordering: .sequentiallyConsistent)

            if ranInline {
                print("[actorDeinit] deinit ran INLINE (not through scheduler)")
            } else {
                print("[actorDeinit] deinit did NOT run inline — must be enqueued")
                deinitRanDuringDrain.store(true, ordering: .sequentiallyConsistent)
            }
        }

        // After ScheduleController.run completes, deinit must have run
        let didRun = deinitRan.load(ordering: .sequentiallyConsistent)
        #expect(didRun, "Deinit should have run by now")

        let wasInline = !deinitRanDuringDrain.load(ordering: .sequentiallyConsistent)
        if wasInline {
            print("[RESULT] Actor deinit runs INLINE — scheduler does NOT control it")
        } else {
            print("[RESULT] Actor deinit is ENQUEUED — scheduler controls it")
        }
    }
}
