//
//  CrossSessionContaminationTest.swift
//
//  Pins down the routing-decision behavior of the method-3 (pthread TLS)
//  branch and exercises a small Task.sleep + actor-hop session that was
//  used during the LLDB investigation of the TLS-stamping bug.
//
//  Background: prior to the TLS-scope fix, methods 1 and 2 of the
//  routing hook stamped pthread TLS on every thread they fired from —
//  including libdispatch timer threads waking Task.sleep continuations.
//  The stamps were never cleared, so they survived session teardown.
//  A concurrent session whose sid happened to match a leftover stamp
//  could be contaminated by foreign work routed via method 3.
//
//  Fix: TLS is now owned by SessionState.dispatch — set at the start of
//  runSynchronously and cleared at the end. Methods 1/2 route only.
//  Confirmed via LLDB: under the diagnostic load (3 sleeps + 3 actor
//  hops) only the drain thread is ever stamped, and stamps come in
//  set/clear pairs. Pre-fix, two distinct tids were stamped.
//

import Foundation
import os
import Testing
import CScheduleHooks
@testable import ScheduleControl

/// Wrapper so we can call `sem.wait()` from inside an async context —
/// the API itself is marked `noasync`, but that only forbids *direct*
/// calls, not wrapped ones.
private func blockOnSemaphore(_ sem: DispatchSemaphore) {
    sem.wait()
}

@Suite("Cross-session TLS contamination", .serialized, .timeLimit(.minutes(1)))
struct CrossSessionContaminationTest {

    private actor HopActor {
        var count = 0
        func hop() -> Int { count += 1; return count }
    }

    private final class ContHolder: @unchecked Sendable {
        private let lock = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(initialState: nil)
        func store(_ cont: CheckedContinuation<Void, Never>) { lock.withLock { $0 = cont } }
        func take() -> CheckedContinuation<Void, Never>? {
            lock.withLock { c in let tmp = c; c = nil; return tmp }
        }
    }

    /// Routing-decision regression test. Constructs the exact pre-fix
    /// bug state — TLS stamped with a live session's sid on a non-drain
    /// thread — by manually calling `schedule_tls_set_session` on a
    /// dispatch thread, then triggers a non-session-tagged Swift enqueue
    /// from that thread. Method 3 must route to the live session.
    ///
    /// This test does NOT verify the fix (the fix changes how TLS gets
    /// stamped, not what method 3 does given a stamp). It pins down
    /// that the routing decision logic itself remains intact.
    @Test("Method 3 routes to live session when TLS holds a live sid",
          .timeLimit(.minutes(1)))
    func method3RoutesGivenLiveTLSSid() async throws {
        let sessionRef = OSAllocatedUnfairLock<SessionState?>(initialState: nil)
        let sidRef = OSAllocatedUnfairLock<Int?>(initialState: nil)
        let parkHolder = ContHolder()
        let m3BeforeRef = OSAllocatedUnfairLock(initialState: -1)
        let m3AfterRef = OSAllocatedUnfairLock(initialState: -1)

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                try? await ScheduleController.run(scheduleBytes: [0]) {
                    guard let session = ScheduleController._currentSessionStateForTesting() else { return }
                    guard let sid = SessionTag.id else { return }
                    sessionRef.withLock { $0 = session }
                    sidRef.withLock { $0 = sid }
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        parkHolder.store(cont)
                    }
                }
            }

            group.addTask {
                while sessionRef.withLock({ $0 == nil }) {
                    try? await Task.sleep(nanoseconds: 5_000_000)
                }
                let session = sessionRef.withLock { $0 }!
                let sid = sidRef.withLock { $0 }!

                m3BeforeRef.withLock { $0 = session.method3AppendCount }

                let done = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    schedule_tls_set_session(Int64(sid))
                    let dummy = Task.detached(priority: .background) { /* no-op */ }
                    _ = dummy
                    Thread.sleep(forTimeInterval: 0.01)
                    // Clean up: don't leave a stale stamp on this dispatch thread
                    schedule_tls_set_session(-1)
                    done.signal()
                }
                blockOnSemaphore(done)

                m3AfterRef.withLock { $0 = session.method3AppendCount }

                DispatchQueue.global().async {
                    parkHolder.take()?.resume()
                }
            }
        }

        let m3Before = m3BeforeRef.withLock { $0 }
        let m3After = m3AfterRef.withLock { $0 }
        #expect(m3After > m3Before,
                "When TLS holds a live sid, a non-tagged Task enqueue must route into that session via method 3")
    }

    /// Small natural-workload diagnostic. Runs a session that uses
    /// Task.sleep (timer-thread continuation resumes) and actor hops
    /// (ProcessOutOfLineJob during completeFuture). Under the pre-fix
    /// code, methods 1 and 2 stamped TLS on those non-drain threads;
    /// under the post-fix code, only the drain thread is stamped.
    /// Used during LLDB investigation to confirm the fix; kept here as
    /// a smoke test that the fixed routing path doesn't crash or hang
    /// on workloads that exercise both Task.sleep and actor hops.
    @Test("Diagnostic: small session with Task.sleep + actor hops",
          .timeLimit(.minutes(1)))
    func diagnosticSmallSession() async throws {
        try await ScheduleController.run(scheduleBytes: [0]) {
            let actor = HopActor()
            for _ in 0..<3 {
                try? await Task.sleep(nanoseconds: 5_000_000)
                _ = await actor.hop()
            }
        }
    }
}
