import Testing
import Foundation
import os
import SanCovHooks
import Clocks
import Dependencies
@testable import ScheduleControl
@testable import PropertyTestingKit
@testable import GenericTimerPoller

// MARK: - Local PollerOp (can't import from GenericTimerPollerTests)

private enum PollerOp {
    case startPolling
    case stopPolling
    case pausePolling
    case resumePolling
    case subscribe
    case cancelLast
    case updateIntervalShort
    case updateIntervalLong
    case updateIntervalClear
}

private func executeLane(_ ops: [PollerOp], on poller: GenericTimerPoller) async {
    var subs: [TaskCancellable] = []

    for op in ops {
        switch op {
        case .startPolling:
            await poller.startPolling()
        case .stopPolling:
            await poller.stopPolling()
        case .pausePolling:
            await poller.pausePolling()
        case .resumePolling:
            await poller.resumePolling()
        case .subscribe:
            let cancellable = await poller.subscribe { }
            subs.append(cancellable)
        case .cancelLast:
            if !subs.isEmpty {
                subs.removeLast().cancel()
            }
        case .updateIntervalShort:
            await poller.updateInterval(.microseconds(10))
        case .updateIntervalLong:
            await poller.updateInterval(.milliseconds(10))
        case .updateIntervalClear:
            await poller.updateInterval(nil)
        }
    }
    for sub in subs { sub.cancel() }
}

private func executeLaneWithClockAdvance(
    _ ops: [PollerOp],
    on poller: GenericTimerPoller,
    clock: TestClock<Duration>
) async {
    var subs: [TaskCancellable] = []

    for op in ops {
        switch op {
        case .startPolling:
            await poller.startPolling()
            await clock.advance(by: .milliseconds(100))
        case .stopPolling:
            await poller.stopPolling()
        case .pausePolling:
            await poller.pausePolling()
        case .resumePolling:
            await poller.resumePolling()
            await clock.advance(by: .milliseconds(100))
        case .subscribe:
            let cancellable = await poller.subscribe { }
            subs.append(cancellable)
        case .cancelLast:
            if !subs.isEmpty {
                subs.removeLast().cancel()
            }
        case .updateIntervalShort:
            await poller.updateInterval(.microseconds(10))
            await clock.advance(by: .microseconds(10))
        case .updateIntervalLong:
            await poller.updateInterval(.milliseconds(10))
            await clock.advance(by: .milliseconds(10))
        case .updateIntervalClear:
            await poller.updateInterval(nil)
        }
    }
    for sub in subs { sub.cancel() }
}

// MARK: - Fixed lane configurations

private let lane1Ops: [PollerOp] = [
    .subscribe, .startPolling, .updateIntervalShort,
    .pausePolling, .resumePolling, .stopPolling
]

private let lane2Ops: [PollerOp] = [
    .subscribe, .startPolling, .updateIntervalLong,
    .cancelLast, .subscribe, .stopPolling
]

// MARK: - Test body helpers

/// Run two concurrent lanes on a fresh GenericTimerPoller with ImmediateClock.
private func runImmediateClockBody() async {
    await withDependencies {
        $0.continuousClock = ImmediateClock()
    } operation: {
        let poller = GenericTimerPoller(defaultInterval: .microseconds(100))
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await executeLane(lane1Ops, on: poller) }
            group.addTask { await executeLane(lane2Ops, on: poller) }
        }
    }
}

/// Run two concurrent lanes on a fresh GenericTimerPoller with TestClock.
private func runTestClockBody() async {
    let testClock = TestClock()
    await withDependencies {
        $0.continuousClock = testClock
    } operation: {
        let poller = GenericTimerPoller(defaultInterval: .milliseconds(100))
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await executeLaneWithClockAdvance(lane1Ops, on: poller, clock: testClock)
            }
            group.addTask {
                await executeLaneWithClockAdvance(lane2Ops, on: poller, clock: testClock)
            }
        }
    }
}

// MARK: - Minimal repro: isolate which mechanism breaks determinism

/// Simple actor for isolation testing — no timers, no streams.
private actor SimpleCounter {
    var value = 0
    func increment() { value += 1 }
    func get() -> Int { value }
}

/// Actor that creates an internal Task.
private actor InternalTaskActor {
    var value = 0
    func doWork() {
        Task { [weak self] in
            await self?.increment()
        }
    }
    func increment() { value += 1 }
    func get() -> Int { value }
}

/// Actor with AsyncStream signaling.
private actor StreamActor {
    private var continuation: AsyncStream<Void>.Continuation?
    private(set) var stream: AsyncStream<Void>?

    func setup() {
        let (stream, cont) = AsyncStream.makeStream(of: Void.self)
        self.stream = stream
        self.continuation = cont
    }

    func signal() {
        continuation?.yield()
    }

    func finish() {
        continuation?.finish()
    }
}

/// Helper: run a body N times under schedule control with a PathTrie,
/// return the number of unique paths observed.
private func measureDeterminism(
    iterations: Int,
    scheduleBytes: [UInt8],
    body: @escaping @Sendable () async -> Void
) async throws -> Int {
    // Warmup
    try await ScheduleController.run(scheduleBytes: scheduleBytes) {
        await body()
    }

    let trie = PathTrie()
    let ctx = SanCovCounters.beginMeasurement()
    SanCovCounters.attachTrie(trie, to: ctx)

    var uniqueCount = 0

    for _ in 0..<iterations {
        SanCovCounters.resetCoverage(ctx)
        trie.reset()

        try await ScheduleController.run(
            scheduleBytes: scheduleBytes,
            coverageContext: ctx.rawContext
        ) {
            await body()
        }

        if trie.isUniquePath {
            uniqueCount += 1
            trie.markTerminal()
        }
    }

    // Keep the trie alive until endMeasurement severs the recorder —
    // instrumented edges keep dispatching into it until then.
    withExtendedLifetime(trie) { SanCovCounters.endMeasurement(ctx) }
    return uniqueCount
}

@Suite("Determinism Isolation", .serialized, .timeLimit(.minutes(1)))
struct DeterminismIsolationTest {

    private static let scheduleBytes: [UInt8] = [
        42, 17, 255, 0, 100, 73, 99, 201,
        3, 88, 150, 44, 12, 77, 233, 56,
        128, 64, 32, 16, 8, 4, 2, 1,
        200, 100, 50, 25, 12, 6, 3, 1,
    ]

    @Test("GenericTimerPoller coverage is deterministic under schedule control (1000 runs)",
          .timeLimit(.minutes(2)))
    func pollerDeterminism1000() async throws {
        // Apply edge filter (same as production fuzz API)
        SanCovCounters.applyEdgeFilter()

        let pollerBody: @Sendable () async -> Void = {
            await withDependencies {
                $0.continuousClock = ImmediateClock()
            } operation: {
                let poller = GenericTimerPoller(defaultInterval: .microseconds(100))
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await executeLane(lane1Ops, on: poller) }
                    group.addTask { await executeLane(lane2Ops, on: poller) }
                }
            }
        }

        // Two warmups with measurement to stabilize
        for _ in 0..<2 {
            let warmCtx = SanCovCounters.beginMeasurement()
            try await ScheduleController.run(
                scheduleBytes: Self.scheduleBytes,
                coverageContext: warmCtx.rawContext
            ) {
                await pollerBody()
            }
            SanCovCounters.endMeasurement(warmCtx)
        }

        // Use a SINGLE measurement context, reset between runs (matches fuzz engine pattern)
        let ctx = SanCovCounters.beginMeasurement()

        // Run 1001 times: first run is reference, remaining 1000 compare
        var reference: SparseCoverage?
        var mismatches = 0
        for i in 0..<1001 {
            SanCovCounters.resetCoverage(ctx)
            try await ScheduleController.run(
                scheduleBytes: Self.scheduleBytes,
                coverageContext: ctx.rawContext
            ) {
                await pollerBody()
            }
            let coverage = try SanCovCounters.snapshotCoveredArrays(with: ctx)

            if reference == nil {
                reference = coverage
                print("Reference: \(coverage.count) edges")
                continue
            }

            guard let ref = reference else { continue }
            if coverage.indices != ref.indices {
                mismatches += 1
                if mismatches <= 2 {
                    print("Mismatch at run \(i): \(coverage.count) edges vs \(ref.count)")
                    let refSet = Set(ref.indices)
                    let runSet = Set(coverage.indices)
                    let onlyRef = refSet.subtracting(runSet).sorted()
                    let onlyRun = runSet.subtracting(refSet).sorted()
                    print("  Only in ref (\(onlyRef.count)): \(onlyRef)")
                    print("  Only in run (\(onlyRun.count)): \(onlyRun)")
                    for edge in onlyRef {
                        let pc = SanCovCounters.getPC(for: Int(edge))
                        var info = Dl_info()
                        let resolved = pc != 0 && dladdr(UnsafeRawPointer(bitPattern: UInt(pc)), &info) != 0
                        let name = resolved && info.dli_sname != nil ? String(cString: info.dli_sname) : "?"
                        print("    ref-only \(edge) pc=0x\(String(pc, radix: 16)) = \(name)")
                    }
                    for edge in onlyRun {
                        let pc = SanCovCounters.getPC(for: Int(edge))
                        var info = Dl_info()
                        let resolved = pc != 0 && dladdr(UnsafeRawPointer(bitPattern: UInt(pc)), &info) != 0
                        let name = resolved && info.dli_sname != nil ? String(cString: info.dli_sname) : "?"
                        print("    run-only \(edge) pc=0x\(String(pc, radix: 16)) = \(name)")
                    }
                }
            }
        }

        print("Result: \(mismatches) mismatches in 1000 runs")
        #expect(mismatches == 0, "Expected 0 mismatches in 1000 runs, got \(mismatches)")
    }

    @Test("Level 1: Two tasks calling actor methods — actor isolation",
          .timeLimit(.minutes(1)))
    func twoTasksCallingActor() async throws {
        let unique = try await measureDeterminism(
            iterations: 50,
            scheduleBytes: Self.scheduleBytes
        ) {
            let counter = SimpleCounter()
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await counter.increment()
                    await counter.increment()
                    await counter.increment()
                }
                group.addTask {
                    await counter.increment()
                    await counter.increment()
                    await counter.increment()
                }
            }
        }
        print("Level 1 (actor calls): \(unique) unique paths in 50 runs")
        #expect(unique == 1, "Expected deterministic, got \(unique) unique paths")
    }

    @Test("Level 2: Actor creates internal Tasks",
          .timeLimit(.minutes(1)))
    func actorWithInternalTasks() async throws {
        let unique = try await measureDeterminism(
            iterations: 50,
            scheduleBytes: Self.scheduleBytes
        ) {
            let actor = InternalTaskActor()
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    await actor.doWork()
                    await actor.doWork()
                }
                group.addTask {
                    await actor.doWork()
                    await actor.doWork()
                }
            }
            // Small delay to let internal tasks complete
            try? await Task.sleep(for: .milliseconds(1))
        }
        print("Level 2 (internal tasks): \(unique) unique paths in 50 runs")
        #expect(unique == 1, "Expected deterministic, got \(unique) unique paths")
    }

    @Test("Level 3: Actor with AsyncStream",
          .timeLimit(.minutes(1)))
    func actorWithAsyncStream() async throws {
        let unique = try await measureDeterminism(
            iterations: 50,
            scheduleBytes: Self.scheduleBytes
        ) {
            let actor = StreamActor()
            await actor.setup()

            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    guard let stream = await actor.stream else { return }
                    for await _ in stream { break }
                }
                group.addTask {
                    await actor.signal()
                    await actor.finish()
                }
            }
        }
        print("Level 3 (AsyncStream): \(unique) unique paths in 50 runs")
        #expect(unique == 1, "Expected deterministic, got \(unique) unique paths")
    }
}

// MARK: - PathTrie reset/reuse bug isolation

@Suite("PathTrie Reuse", .timeLimit(.minutes(1)))
struct PathTrieReuseTest {

    @inline(never)
    static func stableCode() {
        var sum = 0
        for i in 0..<10 { sum += i }
        _ = sum
    }

    @Test("PathTrie identifies repeated path as non-unique after reset")
    func trieResetPreservesTerminals() {
        let trie = PathTrie()
        let ctx = SanCovCounters.beginMeasurement()
        SanCovCounters.attachTrie(trie, to: ctx)

        // Run 1: first path should be unique
        Self.stableCode()
        let firstUnique = trie.isUniquePath
        print("Run 1: isUnique=\(firstUnique)")
        #expect(firstUnique, "First run should always be unique")
        trie.markTerminal()

        // Reset for run 2
        SanCovCounters.resetCoverage(ctx)

        // Run 2: same code, same path — should NOT be unique
        Self.stableCode()
        let secondUnique = trie.isUniquePath
        print("Run 2: isUnique=\(secondUnique)")
        #expect(!secondUnique, "Second run with identical code should NOT be unique — trie should recognize the path")

        // Keep the trie alive until endMeasurement severs the recorder.
        withExtendedLifetime(trie) { SanCovCounters.endMeasurement(ctx) }
    }

    @Test("PathTrie identifies repeated scheduled path as non-unique")
    func trieResetWithScheduleControl() async throws {
        let bytes: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0]

        // Use a SINGLE closure for all runs — different closure literals produce
        // different edge indices (cfU0_ vs cfU1_), which is a closure identity
        // issue, not a scheduling non-determinism issue.
        let body: @Sendable () async -> Void = {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { Self.stableCode() }
                group.addTask { Self.stableCode() }
            }
        }

        // Apply edge filter to remove TQ/TY/TA/Wl noise
        SanCovCounters.applyEdgeFilter()

        // Warmup using the SAME closure
        try await ScheduleController.run(scheduleBytes: bytes) {
            await body()
        }

        let trie = PathTrie()
        let ctx = SanCovCounters.beginMeasurement()
        SanCovCounters.attachTrie(trie, to: ctx)

        // Run 3 times in a loop using the same closure + same call site
        var results: [Bool] = []
        for i in 0..<3 {
            SanCovCounters.resetCoverage(ctx)

            try await ScheduleController.run(
                scheduleBytes: bytes,
                coverageContext: ctx.rawContext
            ) {
                await body()
            }

            let isUnique = trie.isUniquePath
            results.append(isUnique)
            print("Scheduled run \(i): isUnique=\(isUnique)")
            if isUnique {
                trie.markTerminal()
            }
        }

        // Keep the trie alive until endMeasurement severs the recorder.
        withExtendedLifetime(trie) { SanCovCounters.endMeasurement(ctx) }

        #expect(results[0] == true, "First run should be unique")
        #expect(results[1] == false, "Second run should NOT be unique")
        #expect(results[2] == false, "Third run should NOT be unique")
    }
}
