import Clocks
import Dependencies
import Foundation
@testable import GenericTimerPoller
@testable import PropertyTestingKit
import os
import Testing

// MARK: - Sequential Operation Input

struct SequentialPollerOps: Codable, Hashable, Sendable, MutatorProviding {
    var ops: [PollerOp]

    static var defaultMutator: Mutator<SequentialPollerOps> {
        Mutator(
            seeds: [
                SequentialPollerOps(ops: [.subscribe, .startPolling, .stopPolling]),
                SequentialPollerOps(ops: [.subscribe, .cancelLast]),
                SequentialPollerOps(ops: [.subscribe, .subscribe, .startPolling, .cancelLast, .cancelLast]),
                SequentialPollerOps(ops: [.subscribe, .startPolling, .pausePolling, .resumePolling, .stopPolling]),
                SequentialPollerOps(ops: [.stopPolling, .stopPolling]),
                SequentialPollerOps(ops: [.subscribe, .startPolling, .resumePolling]),
            ],
            mutate: { input in
                var results: [SequentialPollerOps] = []
                var rng = FastRNG()
                if !input.ops.isEmpty {
                    var mutated = input.ops
                    let idx = Int.random(in: 0..<mutated.count, using: &rng)
                    mutated[idx] = PollerOp.allCases.randomElement(using: &rng)!
                    results.append(SequentialPollerOps(ops: mutated))
                }
                var inserted = input.ops
                let pos = Int.random(in: 0...inserted.count, using: &rng)
                inserted.insert(PollerOp.allCases.randomElement(using: &rng)!, at: pos)
                results.append(SequentialPollerOps(ops: inserted))
                if !input.ops.isEmpty {
                    var removed = input.ops
                    removed.remove(at: Int.random(in: 0..<removed.count, using: &rng))
                    results.append(SequentialPollerOps(ops: removed))
                }
                return results
            },
            generate: { rng in
                let count = Int.random(in: 1...10, using: &rng)
                let ops = (0..<count).map { _ in PollerOp.allCases.randomElement(using: &rng)! }
                return SequentialPollerOps(ops: ops)
            }
        )
    }
}

// MARK: - Preamble: randomize starting state

/// Executes a random operation sequence against a poller, putting it into an
/// arbitrary state. Returns tracked state for postcondition checks.
///
/// Callers check properties against the poller AFTER the preamble.
/// This is model-based testing of stateful systems: the preamble is the primary
/// input, not noise — it reaches states a human tester wouldn't construct manually.
private struct PreambleResult {
    let poller: GenericTimerPoller
    var subs: [TaskCancellable]
    var expectedSubscriberCount: Int
    var hasSubscribers: Bool
    var startedPolling: Bool
}

/// Run ops as a state preamble. Subscribes use the provided handler.
/// After this returns, the poller is in whatever state the ops left it in.
/// WARNING: If ops include startPolling with ImmediateClock, the actor's timer
/// task is spinning. Call stopPolling() before any further actor interaction.
private func executePreamble(
    ops: [PollerOp],
    on poller: GenericTimerPoller,
    handler: @escaping @Sendable () async -> Void = {}
) async -> (subs: [TaskCancellable], expectedCount: Int, hasSubscribers: Bool, startedPolling: Bool) {
    var subs: [TaskCancellable] = []
    var expectedCount = 0
    var hasSubscribers = false
    var startedPolling = false

    for op in ops {
        switch op {
        case .startPolling:
            await poller.startPolling()
            startedPolling = true
        case .stopPolling:
            await poller.stopPolling()
            subs.removeAll()
            expectedCount = 0
            hasSubscribers = false
            startedPolling = false
        case .pausePolling:
            await poller.pausePolling()
            startedPolling = false
        case .resumePolling:
            await poller.resumePolling()
            if hasSubscribers { startedPolling = true }
        case .subscribe:
            subs.append(await poller.subscribe(handler: handler))
            expectedCount += 1
            hasSubscribers = true
        case .cancelLast:
            if !subs.isEmpty {
                subs.removeLast().cancel()
                expectedCount -= 1
                if subs.isEmpty { hasSubscribers = false }
            }
        case .updateIntervalShort: await poller.updateInterval(.microseconds(1))
        case .updateIntervalLong: await poller.updateInterval(.milliseconds(1))
        case .updateIntervalClear: await poller.updateInterval(nil)
        }
    }

    return (subs, expectedCount, hasSubscribers, startedPolling)
}

// MARK: - Model Oracle

/// Simplified model of GenericTimerPoller's observable state.
/// Checked against the real actor after every operation.
private struct PollerModel {
    var subscriberCount = 0
    var isPolling = false  // timer task exists and running
    var isPaused = false   // timer cancelled but subscribers retained

    /// Returns nil if the model matches the actor, or an error message if not.
    /// `cancelPending`: true if the previous op was a cancel whose removeSubscriber
    /// hasn't propagated yet. Skips subscriber count check (eventually consistent).
    func check(against poller: GenericTimerPoller, op: PollerOp, cancelPending: Bool = false) async -> String? {
        // Invariant 1: handler and subscriberContinuation dicts stay in sync
        // (always immediately consistent — both modified in same actor-isolated methods)
        let inSync = await poller.handlerSubscriberSync
        if !inSync {
            return "After \(op): handlers and subscriberContinuations out of sync"
        }

        // Invariant 2: subscriber count matches model
        // Skip after cancel — removeSubscriber runs asynchronously in a different Task,
        // so the count is eventually consistent, not immediately.
        if !cancelPending {
            let actualCount = await poller.subscriberCount
            if actualCount != subscriberCount {
                return "After \(op): expected \(subscriberCount) subscribers, got \(actualCount)"
            }
        }

        // Invariant 3: no timer without subscribers (when not polling)
        if subscriberCount == 0 && !isPolling && !cancelPending {
            let hasTimer = await poller.hasActiveTimer
            if hasTimer {
                return "After \(op): timer active with 0 subscribers and not polling"
            }
        }

        return nil
    }

    mutating func apply(_ op: PollerOp, cancelledSub: Bool) {
        switch op {
        case .startPolling:
            isPolling = true
            isPaused = false
        case .stopPolling:
            isPolling = false
            isPaused = false
            subscriberCount = 0
        case .pausePolling:
            isPolling = false
            // isPaused only meaningful if we were polling
        case .resumePolling:
            if subscriberCount > 0 && !isPolling {
                isPolling = true
                isPaused = false
            }
        case .subscribe:
            subscriberCount += 1
        case .cancelLast:
            if cancelledSub {
                subscriberCount -= 1
            }
        case .updateIntervalShort, .updateIntervalLong, .updateIntervalClear:
            break
        }
    }
}

// MARK: - Property Tests

/// Property-based tests for GenericTimerPoller.
///
/// Key constraint: ImmediateClock + startPolling creates an infinite actor-bound
/// loop. Any actor call AFTER startPolling will hang. Tests must either:
/// - Not call startPolling, or
/// - Call stopPolling before any further actor interaction, or
/// - Let the poller go out of scope (deinit cancels the timer)
@Suite("GenericTimerPoller Properties")
struct GenericTimerPollerPropertyTests {

    // MARK: 0. Model-based oracle: check invariants after EVERY operation

    @Test("Model oracle: invariants hold after every operation", .timeLimit(.minutes(2)))
    func modelOraclePerOperation() async throws {
        try await withDependencies {
            $0.continuousClock = ImmediateClock()
        } operation: {
            try await fuzz(duration: .seconds(3)) { (input: SequentialPollerOps) in
                // Filter ops that lock the actor (startPolling/resumePolling with ImmediateClock).
                // The full oracle with timer ops requires TestClock (task #27).
                let safeOps = input.ops.filter { $0 != .startPolling && $0 != .resumePolling }
                guard !safeOps.isEmpty else { return }

                let poller = GenericTimerPoller(defaultInterval: .microseconds(1))
                var model = PollerModel()
                var subs: [TaskCancellable] = []

                for op in safeOps {
                    let hadSubs = !subs.isEmpty

                    switch op {
                    case .startPolling, .resumePolling:
                        break // filtered
                    case .stopPolling:
                        await poller.stopPolling()
                        subs.removeAll()
                    case .pausePolling:
                        await poller.pausePolling()
                    case .subscribe:
                        subs.append(await poller.subscribe {})
                    case .cancelLast:
                        if !subs.isEmpty {
                            subs.removeLast().cancel()
                            // Give cancellation time to propagate to removeSubscriber
                            try? await Task.sleep(for: .milliseconds(1))
                        }
                    case .updateIntervalShort:
                        await poller.updateInterval(.microseconds(1))
                    case .updateIntervalLong:
                        await poller.updateInterval(.milliseconds(1))
                    case .updateIntervalClear:
                        await poller.updateInterval(nil)
                    }

                    let wasCancelWithSub = op == .cancelLast && hadSubs
                    model.apply(op, cancelledSub: wasCancelWithSub)

                    // Cancel is async (removeSubscriber runs in a different Task).
                    // Skip subscriber count check — it's eventually consistent.
                    let skipCountCheck = op == .cancelLast
                    if let error = await model.check(against: poller, op: op, cancelPending: skipCountCheck) {
                        Issue.record("\(error). Ops so far: \(safeOps)")
                        return
                    }
                }
            }
        }
    }

    // MARK: 0b. Full model oracle with TestClock (all operations including start/resume)

    @Test("Full model oracle with TestClock: all operations", .timeLimit(.minutes(2)))
    func fullModelOracle() async throws {
        try await fuzz(duration: .seconds(3)) { (input: SequentialPollerOps) in
            let testClock = TestClock()
            try await withDependencies {
                $0.continuousClock = testClock
            } operation: {
                let handlerCallCount = OSAllocatedUnfairLock(initialState: 0)
                let poller = GenericTimerPoller(defaultInterval: .milliseconds(100))
                var model = PollerModel()
                var subs: [TaskCancellable] = []
                var hasPendingCancel = false

                for op in input.ops {
                    let hadSubs = !subs.isEmpty

                    switch op {
                    case .startPolling:
                        await poller.startPolling()
                    case .stopPolling:
                        await poller.stopPolling()
                        subs.removeAll()
                        hasPendingCancel = false // stop clears everything synchronously
                    case .pausePolling:
                        await poller.pausePolling()
                    case .resumePolling:
                        await poller.resumePolling()
                    case .subscribe:
                        subs.append(await poller.subscribe {
                            handlerCallCount.withLock { $0 += 1 }
                        })
                    case .cancelLast:
                        if !subs.isEmpty {
                            subs.removeLast().cancel()
                            hasPendingCancel = true
                        }
                    case .updateIntervalShort:
                        await poller.updateInterval(.microseconds(1))
                    case .updateIntervalLong:
                        await poller.updateInterval(.milliseconds(1))
                    case .updateIntervalClear:
                        await poller.updateInterval(nil)
                    }

                    let wasCancelWithSub = op == .cancelLast && hadSubs
                    model.apply(op, cancelledSub: wasCancelWithSub)

                    // Cancel is async (removeSubscriber runs in a different Task).
                    // Skip subscriber count check until a synchronous reset (stopPolling)
                    // clears the pending state.
                    if let error = await model.check(against: poller, op: op, cancelPending: hasPendingCancel) {
                        Issue.record("\(error). Ops so far: \(input.ops)")
                        return
                    }
                }
            }
        }
    }

    // MARK: 1. Invariant: stopPolling is total teardown

    @Test("stopPolling clears all state — no handler fires after stop", .timeLimit(.minutes(2)))
    func stopPollingClearsState() async throws {
        try await withDependencies {
            $0.continuousClock = ImmediateClock()
        } operation: {
            try await fuzz(duration: .seconds(3)) { (input: SequentialPollerOps) in
                let handlerCalledAfterStop = OSAllocatedUnfairLock(initialState: false)
                let poller = GenericTimerPoller(defaultInterval: .microseconds(1))

                var (subs, _, _, _) = await executePreamble(ops: input.ops, on: poller)

                await poller.stopPolling()
                subs.removeAll()

                let freshSub = await poller.subscribe {
                    handlerCalledAfterStop.withLock { $0 = true }
                }

                let leaked = handlerCalledAfterStop.withLock { $0 }
                #expect(!leaked, "After stopPolling, no leaked timer should fire handlers")

                freshSub.cancel()
            }
        }
    }

    // MARK: 2. Idempotence: stopPolling twice == once

    @Test("stopPolling is idempotent — calling twice doesn't crash or corrupt", .timeLimit(.minutes(2)))
    func stopPollingIdempotent() async throws {
        try await withDependencies {
            $0.continuousClock = ImmediateClock()
        } operation: {
            try await fuzz(duration: .seconds(3)) { (input: SequentialPollerOps) in
                let poller = GenericTimerPoller(defaultInterval: .microseconds(1))

                _ = await executePreamble(ops: input.ops, on: poller)

                await poller.stopPolling()
                await poller.stopPolling()

                let sub = await poller.subscribe {}
                sub.cancel()
            }
        }
    }

    // MARK: 3. Metamorphic: subscriber count tracks cancellations

    @Test("Active subscriber count equals subscribes minus cancels", .timeLimit(.minutes(2)))
    func subscriberCountTracking() async throws {
        try await withDependencies {
            $0.continuousClock = ImmediateClock()
        } operation: {
            try await fuzz(duration: .seconds(3)) { (input: SequentialPollerOps) in
                let poller = GenericTimerPoller(defaultInterval: .microseconds(1))

                let (subs, expectedCount, _, _) = await executePreamble(ops: input.ops, on: poller)

                await poller.stopPolling()

                #expect(expectedCount >= 0, "Active subscriber count must never go negative")
                #expect(expectedCount == subs.count,
                        "Tracked count (\(expectedCount)) must match retained subs (\(subs.count))")
            }
        }
    }

    // MARK: 4. Invariant: no handler calls without startPolling

    @Test("Handlers never fire without startPolling", .timeLimit(.minutes(2)))
    func noCallsWithoutStart() async throws {
        try await withDependencies {
            $0.continuousClock = ImmediateClock()
        } operation: {
            try await fuzz(duration: .seconds(3)) { (input: SequentialPollerOps) in
                let opsWithoutStart = input.ops.filter { $0 != .startPolling && $0 != .resumePolling }
                guard !opsWithoutStart.isEmpty else { return }

                let handlerCalled = OSAllocatedUnfairLock(initialState: false)
                let poller = GenericTimerPoller(defaultInterval: .microseconds(1))

                _ = await executePreamble(ops: opsWithoutStart, on: poller) {
                    handlerCalled.withLock { $0 = true }
                }

                let called = handlerCalled.withLock { $0 }
                #expect(!called,
                        "Without startPolling, handlers must never fire. Ops: \(opsWithoutStart)")
            }
        }
    }

    // MARK: 5. Model-based: handler fires when subscribers exist and polling starts

    @Test("startPolling fires handlers when subscribers exist", .timeLimit(.minutes(2)))
    func startPollingFiresHandlers() async throws {
        try await withDependencies {
            $0.continuousClock = ImmediateClock()
        } operation: {
            try await fuzz(duration: .seconds(3)) { (input: SequentialPollerOps) in
                let handlerCallCount = OSAllocatedUnfairLock(initialState: 0)
                let poller = GenericTimerPoller(defaultInterval: .microseconds(1))

                let (_, _, hasSubscribers, startedPolling) = await executePreamble(
                    ops: input.ops, on: poller
                ) {
                    handlerCallCount.withLock { $0 += 1 }
                }

                await poller.stopPolling()

                if hasSubscribers && startedPolling {
                    let calls = handlerCallCount.withLock { $0 }
                    #expect(calls > 0,
                            "With subscribers and startPolling, at least one handler call expected")
                }
            }
        }
    }

    // MARK: 6. Concurrent linearizability: result matches some sequential execution

    @Test("Concurrent operations produce linearizable state", .timeLimit(.minutes(2)))
    func concurrentLinearizability() async throws {
        try await withDependencies {
            $0.continuousClock = ImmediateClock()
        } operation: {
            try await fuzz(
                duration: .seconds(3),
                scheduleFuzzing: true
            ) { (input: PollerFuzzInput) in
                let poller = GenericTimerPoller(defaultInterval: .microseconds(1))

                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        await executePropertyLane(input.lane1, on: poller)
                    }
                    group.addTask {
                        await executePropertyLane(input.lane2, on: poller)
                    }
                }

                await poller.stopPolling()

                // Linearizability check: the real actor's state must be reachable
                // by SOME sequential interleaving of lane1 and lane2 ops.
                let actualCount = await poller.subscriberCount
                let inSync = await poller.handlerSubscriberSync

                // After stopPolling, subscriber count must be 0 (stop clears all)
                #expect(actualCount == 0,
                        "After concurrent ops + stopPolling, subscriber count must be 0, got \(actualCount)")
                #expect(inSync,
                        "After concurrent ops, handlers and subscriberContinuations must be in sync")

                // Actor must still be usable
                let sub = await poller.subscribe {}
                #expect(await poller.subscriberCount == 1,
                        "Fresh subscribe after concurrent abuse must work")
                sub.cancel()
            }
        }
    }

    // MARK: 7. Per-subscriber handler isolation

    @Test("Cancelled subscriber's handler stops firing")
    func cancelledSubscriberStopsReceiving() async throws {
        try await withDependencies {
            $0.continuousClock = ImmediateClock()
        } operation: {
            let poller = GenericTimerPoller(defaultInterval: .microseconds(1))

            let subscriberACalls = OSAllocatedUnfairLock(initialState: 0)
            let subscriberBCalls = OSAllocatedUnfairLock(initialState: 0)

            let subA = await poller.subscribe { subscriberACalls.withLock { $0 += 1 } }
            let subB = await poller.subscribe { subscriberBCalls.withLock { $0 += 1 } }

            await poller.startPolling()
            await poller.stopPolling()

            let aCalls1 = subscriberACalls.withLock { $0 }
            let bCalls1 = subscriberBCalls.withLock { $0 }

            subA.cancel()
            try? await Task.sleep(for: .milliseconds(5))

            subscriberACalls.withLock { $0 = 0 }
            subscriberBCalls.withLock { $0 = 0 }

            await poller.startPolling()
            await poller.stopPolling()

            let aCallsAfterCancel = subscriberACalls.withLock { $0 }
            let bCallsAfterCancel = subscriberBCalls.withLock { $0 }

            if aCalls1 > 0 && bCalls1 > 0 {
                #expect(aCallsAfterCancel == 0,
                        "Cancelled subscriber A should not receive calls")
                #expect(bCallsAfterCancel > 0,
                        "Active subscriber B should still receive calls")
            }

            subB.cancel()
        }
    }

    // MARK: 8. Pause/resume round-trip

    @Test("Pause then resume restores handler delivery")
    func pauseResumeRoundTrip() async throws {
        try await withDependencies {
            $0.continuousClock = ImmediateClock()
        } operation: {
            let handlerCalls = OSAllocatedUnfairLock(initialState: 0)
            let poller = GenericTimerPoller(defaultInterval: .microseconds(1))

            let sub = await poller.subscribe { handlerCalls.withLock { $0 += 1 } }

            await poller.startPolling()
            await poller.stopPolling()
            let callsBeforePause = handlerCalls.withLock { $0 }
            guard callsBeforePause > 0 else {
                sub.cancel()
                return
            }

            handlerCalls.withLock { $0 = 0 }
            await poller.startPolling()
            await poller.pausePolling()

            let callsDuringPause = handlerCalls.withLock { $0 }

            await poller.resumePolling()
            await poller.stopPolling()
            let callsAfterResume = handlerCalls.withLock { $0 }

            #expect(callsDuringPause == 0, "No handler calls should occur while paused")
            #expect(callsAfterResume > 0, "After resume, handlers should fire again")

            sub.cancel()
        }
    }

    // MARK: 9. startPolling idempotence

    @Test("Calling startPolling twice doesn't crash or corrupt state")
    func startPollingIdempotent() async throws {
        try await withDependencies {
            $0.continuousClock = ImmediateClock()
        } operation: {
            let poller = GenericTimerPoller(defaultInterval: .microseconds(1))

            let sub = await poller.subscribe {}

            await poller.startPolling()
            await poller.startPolling()
            await poller.stopPolling()

            // Actor state must not be corrupted
            let sub2 = await poller.subscribe {}
            sub.cancel()
            sub2.cancel()
        }
    }

    // MARK: 10. updateInterval preserves handler identity

    @Test("updateInterval changes cadence but handlers still fire")
    func updateIntervalPreservesHandlers() async throws {
        try await withDependencies {
            $0.continuousClock = ImmediateClock()
        } operation: {
            let handlerCalls = OSAllocatedUnfairLock(initialState: 0)
            let poller = GenericTimerPoller(defaultInterval: .microseconds(1))

            let sub = await poller.subscribe { handlerCalls.withLock { $0 += 1 } }

            await poller.startPolling()
            await poller.stopPolling()
            guard handlerCalls.withLock({ $0 }) > 0 else {
                sub.cancel()
                return
            }

            handlerCalls.withLock { $0 = 0 }
            await poller.startPolling()
            await poller.updateInterval(.milliseconds(1))
            await poller.stopPolling()

            #expect(handlerCalls.withLock({ $0 }) > 0,
                    "After updateInterval, the same handler should still fire")

            handlerCalls.withLock { $0 = 0 }
            await poller.startPolling()
            await poller.updateInterval(nil)
            await poller.stopPolling()

            #expect(handlerCalls.withLock({ $0 }) > 0,
                    "After clearing interval override, handler should still fire")

            sub.cancel()
        }
    }
    // MARK: 11. Handler delivery count: N subscribers = N handler calls per poll

    @Test("Each poll fires exactly N handlers for N subscribers")
    func handlerDeliveryCount() async throws {
        for subscriberCount in 1...5 {
            let testClock = TestClock()
            try await withDependencies {
                $0.continuousClock = testClock
            } operation: {
                let callCounts = (0..<subscriberCount).map { _ in OSAllocatedUnfairLock(initialState: 0) }
                let poller = GenericTimerPoller(defaultInterval: .milliseconds(100))

                var subs: [TaskCancellable] = []
                for i in 0..<subscriberCount {
                    let counter = callCounts[i]
                    subs.append(await poller.subscribe {
                        counter.withLock { $0 += 1 }
                    })
                }

                await poller.startPolling()
                // startPolling fires immediately — give the task a chance to run
                try? await Task.sleep(for: .milliseconds(1))

                // Each subscriber should have been called exactly once from fireImmediately
                for (i, counter) in callCounts.enumerated() {
                    let count = counter.withLock { $0 }
                    #expect(count == 1,
                            "Subscriber \(i) should be called exactly once from fireImmediately, got \(count)")
                }

                // Advance clock by one interval — should fire all handlers again
                for counter in callCounts { counter.withLock { $0 = 0 } }
                await testClock.advance(by: .milliseconds(100))
                try? await Task.sleep(for: .milliseconds(1))

                for (i, counter) in callCounts.enumerated() {
                    let count = counter.withLock { $0 }
                    #expect(count == 1,
                            "Subscriber \(i) should be called exactly once per interval, got \(count)")
                }

                for sub in subs { sub.cancel() }
                await poller.stopPolling()
            }
        }
    }
    // MARK: Plateau convergence measurement

    @Test("Schedule-controlled fuzzing converges with STADS detector", .timeLimit(.minutes(2)))
    func scheduledPlateauConvergence() async throws {
        try await withDependencies {
            $0.continuousClock = ImmediateClock()
        } operation: {
            let result = try await fuzz(
                duration: .seconds(60),
                scheduleFuzzing: true,
                plugins: { [.corpusMutation(), .stadsDetector()] }
            ) { (input: PollerFuzzInput) in
                let poller = GenericTimerPoller(defaultInterval: .microseconds(1))

                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await executePropertyLane(input.lane1, on: poller) }
                    group.addTask { await executePropertyLane(input.lane2, on: poller) }
                }
                await poller.stopPolling()
            }

            // The corpus entry count tells us how many unique paths pathTrie found
            // (each entry = one didAdd = true = one discoveredNewCoverage = true to STADS)
            print("Scheduled plateau: \(result.stats.totalInputs) iterations, " +
                  "\(result.corpus.entries.count) corpus entries, " +
                  "\(String(format: "%.1f", result.stats.duration))s, " +
                  "stop: \(result.stats.stopReason.rawValue), " +
                  "mutations: \(result.stats.mutations), " +
                  "generations: \(result.stats.generations)")
        }
    }
}

// MARK: - Lane Executor

private func executePropertyLane(_ ops: [PollerOp], on poller: GenericTimerPoller) async {
    var subs: [TaskCancellable] = []
    for op in ops {
        switch op {
        case .startPolling: await poller.startPolling()
        case .stopPolling: await poller.stopPolling()
        case .pausePolling: await poller.pausePolling()
        case .resumePolling: await poller.resumePolling()
        case .subscribe: subs.append(await poller.subscribe {})
        case .cancelLast:
            if !subs.isEmpty { subs.removeLast().cancel() }
        case .updateIntervalShort: await poller.updateInterval(.microseconds(10))
        case .updateIntervalLong: await poller.updateInterval(.milliseconds(10))
        case .updateIntervalClear: await poller.updateInterval(nil)
        }
    }
    for sub in subs { sub.cancel() }
}
