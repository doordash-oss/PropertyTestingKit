//
//  RoutingBranchTests.swift
//  Verifies which routing-hook branch fires for each concurrency pattern,
//  broken down by JobKind at each branch.
//

import Foundation
@testable import ScheduleControl
import Testing

@Suite("Routing hook branch verification", .serialized, .timeLimit(.minutes(1)))
struct RoutingBranchTests {

    private static let scheduleBytes: [UInt8] = [42, 17, 255, 0, 100, 73, 99, 201]

    private static func forceSuspension() async {
        await Task.yield()
    }

    private actor TestActor {
        var counter = 0
        func increment() { counter += 1 }
        func value() -> Int { counter }
    }

    private static func kindName(_ kind: Int) -> String {
        switch kind {
        case 0:   return "AsyncTask"
        case 192: return "DefaultActorInline"
        case 193: return "DefaultActorSeparate"
        case 194: return "DefaultActorOverride"
        default:  return "kind=\(kind)"
        }
    }

    private static func dumpKinds(_ label: String, _ map: [Int: Int]) {
        if map.isEmpty { print("    \(label): (none)"); return }
        let parts = map.sorted { $0.key < $1.key }
            .map { "\(kindName($0.key))×\($0.value)" }
            .joined(separator: ", ")
        print("    \(label): \(parts)")
    }

    private static func dumpAll(_ title: String) {
        print("== \(title) ==")
        print("  m1=\(RoutingHookCounters.method1Hits)  m2=\(RoutingHookCounters.method2Hits)  m3=\(RoutingHookCounters.method3Hits)  pt=\(RoutingHookCounters.passThroughHits)")
        dumpKinds("m1 kinds", RoutingHookCounters.method1JobKinds)
        dumpKinds("m2 kinds", RoutingHookCounters.method2JobKinds)
        dumpKinds("m3 kinds", RoutingHookCounters.method3JobKinds)
        dumpKinds("pt kinds", RoutingHookCounters.passThroughJobKinds)
    }

    @Test("Sequential Task.yield() inside a session",
          .timeLimit(.minutes(1)))
    func sequentialYields() async throws {
        RoutingHookCounters.reset()
        try await ScheduleController.run(scheduleBytes: Self.scheduleBytes) {
            for _ in 0..<10 { await Self.forceSuspension() }
        }
        Self.dumpAll("Sequential yields (10x)")
        #expect(RoutingHookCounters.method1Hits > 0)
    }

    @Test("TaskGroup with N children inside a session",
          .timeLimit(.minutes(1)))
    func taskGroupChildren() async throws {
        RoutingHookCounters.reset()
        try await ScheduleController.run(scheduleBytes: Self.scheduleBytes) {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<5 {
                    group.addTask { await Self.forceSuspension() }
                }
            }
        }
        Self.dumpAll("TaskGroup (5 children)")
        #expect(RoutingHookCounters.method1Hits > 0)
    }

    @Test("Actor method calls inside a session",
          .timeLimit(.minutes(1)))
    func actorCalls() async throws {
        RoutingHookCounters.reset()
        try await ScheduleController.run(scheduleBytes: Self.scheduleBytes) {
            let actor = TestActor()
            for _ in 0..<10 { await actor.increment() }
            _ = await actor.value()
        }
        Self.dumpAll("Actor calls (10x increment)")
        #expect(RoutingHookCounters.method1Hits > 0)
    }

    @Test("Task.detached inside a session",
          .timeLimit(.minutes(1)))
    func detachedTask() async throws {
        RoutingHookCounters.reset()
        try await ScheduleController.run(scheduleBytes: Self.scheduleBytes) {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await Task.detached {
                        await Self.forceSuspension()
                    }.value
                }
            }
        }
        Self.dumpAll("Detached inside TaskGroup child")
        #expect(RoutingHookCounters.method3Hits + RoutingHookCounters.passThroughHits > 0)
    }

    @Test("TaskGroup + actor hops inside a session",
          .timeLimit(.minutes(1)))
    func taskGroupPlusActor() async throws {
        RoutingHookCounters.reset()
        try await ScheduleController.run(scheduleBytes: Self.scheduleBytes) {
            let actor = TestActor()
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<8 {
                    group.addTask {
                        await actor.increment()
                        await actor.increment()
                    }
                }
            }
        }
        Self.dumpAll("TaskGroup (8 children) + actor hops")
    }

    // Note: a `noSession` test that asserts global RoutingHookCounters
    // is unsound under swift-testing's default parallel-suite execution.
    // The counters are process-wide, so any concurrent
    // `ScheduleController.run` in another suite pollutes them during the
    // window of this test. The behavior such a test would target —
    // `_hookPtr` being nil after `_sessions` becomes empty — is implicit
    // in the cleanup path and would surface elsewhere if broken.
}
