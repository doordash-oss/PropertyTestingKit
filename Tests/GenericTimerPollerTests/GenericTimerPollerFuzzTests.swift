// Copyright 2026 DoorDash, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

//  Fuzz test for GenericTimerPoller to find continuation misuse crashes.
//  Generates concurrent operation sequences and runs them against the poller.
//

import Clocks
import Dependencies
import Foundation
@testable import GenericTimerPoller
@testable import PropertyTestingKit
@testable import ScheduleControl
import SanCovHooks
import Synchronization
import Testing

// MARK: - Fuzz Input Model

enum PollerOp: UInt8, Codable, Hashable, Sendable, CaseIterable {
    case startPolling = 0
    case stopPolling = 1
    case pausePolling = 2
    case resumePolling = 3
    case subscribe = 4
    case cancelLast = 5
    case updateIntervalShort = 6
    case updateIntervalLong = 7
    case updateIntervalClear = 8
}

// MARK: - Constant Input (for controlled experiments)

/// A PollerFuzzInput wrapper whose mutator always returns the same fixed input.
/// Used to isolate schedule-byte variation from input variation.
struct ConstantPollerInput: Codable, Hashable, Sendable, MutatorProviding {
    var lane1: [PollerOp]
    var lane2: [PollerOp]

    static var defaultMutator: Mutator<ConstantPollerInput> {
        // Operations that exercise concurrent actor contention without
        // unbounded timer loops (startPolling + ImmediateClock spins
        // indefinitely, making iteration count timing-dependent).
        let fixed = ConstantPollerInput(
            lane1: [.subscribe, .subscribe, .cancelLast, .subscribe, .cancelLast, .cancelLast],
            lane2: [.subscribe, .cancelLast, .subscribe, .subscribe, .cancelLast, .cancelLast]
        )
        return Mutator(
            seeds: [fixed],
            mutate: { _, _ in fixed },
            generate: { _ in fixed }
        )
    }
}

// MARK: - Fuzz Input Model

struct PollerFuzzInput: Codable, Hashable, Sendable, MutatorProviding {
    var lane1: [PollerOp]
    var lane2: [PollerOp]

    static var defaultMutator: Mutator<PollerFuzzInput> {
        Mutator(
            seeds: [
                // Basic lifecycle
                PollerFuzzInput(
                    lane1: [.subscribe, .startPolling, .stopPolling],
                    lane2: [.subscribe, .startPolling, .cancelLast]
                ),
                // Rapid subscribe/unsubscribe while polling
                PollerFuzzInput(
                    lane1: [.subscribe, .subscribe, .startPolling, .cancelLast, .cancelLast],
                    lane2: [.startPolling, .stopPolling, .startPolling, .stopPolling]
                ),
                // Pause/resume interleaved with subscribe
                PollerFuzzInput(
                    lane1: [.subscribe, .startPolling, .pausePolling, .resumePolling, .stopPolling],
                    lane2: [.subscribe, .cancelLast, .subscribe, .cancelLast]
                ),
                // Interval updates during polling
                PollerFuzzInput(
                    lane1: [.subscribe, .startPolling, .updateIntervalShort, .updateIntervalLong, .updateIntervalClear],
                    lane2: [.subscribe, .startPolling, .updateIntervalShort, .stopPolling]
                ),
                // Many concurrent subscribes then mass cancel
                PollerFuzzInput(
                    lane1: [.subscribe, .subscribe, .subscribe, .subscribe, .startPolling],
                    lane2: [.cancelLast, .cancelLast, .cancelLast, .cancelLast, .stopPolling]
                ),
            ],
            mutate: { input, rng in
                var mutations: [PollerFuzzInput] = []
                let ops = PollerOp.allCases

                // Flip a random op in lane1
                if !input.lane1.isEmpty {
                    var copy = input
                    let i = Int.random(in: 0..<copy.lane1.count, using: &rng)
                    copy.lane1[i] = ops[Int(copy.lane1[i].rawValue + 1) % ops.count]
                    mutations.append(copy)
                }
                // Flip a random op in lane2
                if !input.lane2.isEmpty {
                    var copy = input
                    let i = Int.random(in: 0..<copy.lane2.count, using: &rng)
                    copy.lane2[i] = ops[Int(copy.lane2[i].rawValue + 1) % ops.count]
                    mutations.append(copy)
                }

                // Append a random op to a lane
                let op = ops[Int.random(in: 0..<ops.count, using: &rng)]
                var appended = input
                if Bool.random(using: &rng) {
                    appended.lane1.append(op)
                } else {
                    appended.lane2.append(op)
                }
                mutations.append(appended)

                // Remove an op from a lane
                if input.lane1.count > 1 {
                    var copy = input
                    copy.lane1.removeLast()
                    mutations.append(copy)
                }
                if input.lane2.count > 1 {
                    var copy = input
                    copy.lane2.removeLast()
                    mutations.append(copy)
                }

                // Swap lanes
                mutations.append(PollerFuzzInput(lane1: input.lane2, lane2: input.lane1))

                return mutations[Int.random(in: 0..<mutations.count, using: &rng)]
            },
            generate: { rng in
                let len1 = Int.random(in: 3...12, using: &rng)
                let len2 = Int.random(in: 3...12, using: &rng)
                return PollerFuzzInput(
                    lane1: (0..<len1).map { _ in randomOp(using: &rng) },
                    lane2: (0..<len2).map { _ in randomOp(using: &rng) }
                )
            }
        )
    }

    private static func randomOp(using rng: inout FastRNG) -> PollerOp {
        let index = Int.random(in: 0..<PollerOp.allCases.count, using: &rng)
        return PollerOp(rawValue: UInt8(index)) ?? .startPolling
    }
}

// MARK: - Sequential Fuzz Input

struct SequentialPollerInput: Codable, Hashable, Sendable, MutatorProviding {
    var ops: [PollerOp]

    static var defaultMutator: Mutator<SequentialPollerInput> {
        Mutator(
            seeds: [
                SequentialPollerInput(ops: [.subscribe, .startPolling, .stopPolling]),
                SequentialPollerInput(ops: [.subscribe, .startPolling, .cancelLast]),
                SequentialPollerInput(ops: [.subscribe, .startPolling, .pausePolling, .resumePolling, .stopPolling]),
                SequentialPollerInput(ops: [.subscribe, .subscribe, .startPolling, .cancelLast, .cancelLast, .stopPolling]),
                SequentialPollerInput(ops: [.subscribe, .startPolling, .updateIntervalShort, .updateIntervalLong, .updateIntervalClear, .stopPolling]),
            ],
            mutate: { input, rng in
                var mutations: [SequentialPollerInput] = []
                let ops = PollerOp.allCases

                if !input.ops.isEmpty {
                    var copy = input
                    let i = Int.random(in: 0..<copy.ops.count, using: &rng)
                    copy.ops[i] = ops[Int(copy.ops[i].rawValue + 1) % ops.count]
                    mutations.append(copy)
                }
                var appended = input
                appended.ops.append(ops[Int.random(in: 0..<ops.count, using: &rng)])
                mutations.append(appended)
                if input.ops.count > 1 {
                    var copy = input
                    copy.ops.removeLast()
                    mutations.append(copy)
                }
                return mutations[Int.random(in: 0..<mutations.count, using: &rng)]
            },
            generate: { rng in
                let len = Int.random(in: 3...12, using: &rng)
                return SequentialPollerInput(
                    ops: (0..<len).map { _ in
                        let index = Int.random(in: 0..<PollerOp.allCases.count, using: &rng)
                        return PollerOp(rawValue: UInt8(index)) ?? .startPolling
                    }
                )
            }
        )
    }
}

// MARK: - Fuzz Tests

@Suite("GenericTimerPoller Fuzz Tests")
struct GenericTimerPollerFuzzTests {

    @Test("Sequential operations don't crash")
    func fuzzSequentialOperations() async throws {
        try await withDependencies {
            $0.continuousClock = ImmediateClock()
        } operation: {
            try await fuzz(
                duration: .seconds(30),
                persistence: .ephemeral
            ) { (input: SequentialPollerInput) in
                let poller = GenericTimerPoller(defaultInterval: .microseconds(100))
                await executeLane(input.ops, on: poller)
            }
        }
    }

    @Test("Concurrent operations don't crash")
    func fuzzConcurrentOperations() async throws {
        try await withDependencies {
            $0.continuousClock = ImmediateClock()
        } operation: {
            let result = try await fuzz(
                duration: .seconds(30),
                persistence: .ephemeral
            ) { (input: PollerFuzzInput) in
                let poller = GenericTimerPoller(defaultInterval: .microseconds(100))

                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        await executeLane(input.lane1, on: poller)
                    }
                    group.addTask {
                        await executeLane(input.lane2, on: poller)
                    }
                }

                // Poller deinits here — deinit cancels task and finishes continuation
            }
            for (i, entry) in result.corpus.entries.enumerated() {
                let edges = entry.sparseCoverage.indices.sorted()
                print("Entry \(i): \(edges.count) edges, input=\(entry.input)")
            }
        }
    }

    @Test("Schedule-fuzzed concurrent operations don't crash", .timeLimit(.minutes(2)))
    func fuzzScheduledConcurrentOperations() async throws {
        try await withDependencies {
            $0.continuousClock = ImmediateClock()
        } operation: {
            let iterCounter = Atomic<Int>(0)
            let result = try await fuzz(
                duration: .seconds(3),
                persistence: .ephemeral,
                scheduleFuzzing: true
            ) { (input: PollerFuzzInput) in
                let iter = iterCounter.wrappingAdd(1, ordering: .relaxed).newValue
                if iter <= 10 || iter % 500 == 0 {
                    let l1 = input.lane1.map { "\($0)" }.joined(separator: ", ")
                    let l2 = input.lane2.map { "\($0)" }.joined(separator: ", ")
                    print("[INPUT iter=\(iter)] lane1=[\(l1)] lane2=[\(l2)]")
                }

                let poller = GenericTimerPoller(defaultInterval: .microseconds(100))

                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        await executeLane(input.lane1, on: poller)
                    }
                    group.addTask {
                        await executeLane(input.lane2, on: poller)
                    }
                }
            }
            let allEdges = result.corpus.entries.reduce(into: Set<UInt32>()) { $0.formUnion($1.sparseCoverage.indices) }
            print("Schedule fuzz: \(result.stats.totalInputs) iterations, \(result.corpus.entries.count) corpus entries, \(String(format: "%.1f", result.stats.inputsPerSecond)) iter/s, \(allEdges.count) unique edges total")
        }
    }

    @Test("Fixed input with schedule fuzzing produces bounded unique paths", .timeLimit(.minutes(2)))
    func fixedInputBoundedPaths() async throws {
        try await withDependencies {
            $0.continuousClock = ImmediateClock()
        } operation: {
            let result = try await fuzz(
                duration: .milliseconds(100),
                persistence: .ephemeral,
                scheduleFuzzing: true
            ) { (input: ConstantPollerInput) in
                let poller = GenericTimerPoller(defaultInterval: .microseconds(100))

                await withTaskGroup(of: Void.self) { group in
                    group.addTask {
                        await executeLane(input.lane1, on: poller)
                    }
                    group.addTask {
                        await executeLane(input.lane2, on: poller)
                    }
                }
            }

            let corpusCount = result.corpus.entries.count
            print("Fixed input: \(result.stats.totalInputs) iterations, \(corpusCount) corpus entries")

            // Dump edge -> PC mapping for all edges seen
            let allEdges = result.corpus.entries.reduce(into: Set<UInt32>()) { $0.formUnion($1.sparseCoverage.indices) }
            for edge in allEdges.sorted() {
                let pc = SanCovCounters.getPC(for: Int(edge))
                print("[EDGE_PC] \(edge)|\(pc)")
            }

            #expect(
                corpusCount <= 10,
                "Expected at most ~5-10 unique paths for a fixed input, got \(corpusCount)"
            )
        }
    }

    // MARK: - Schedule control reproducibility

    @Test("Uncontrolled: constant input produces many corpus entries (non-deterministic paths)",
          .timeLimit(.minutes(1)))
    func uncontrolledConstantInputManyPaths() async throws {
        try await withDependencies {
            $0.continuousClock = ImmediateClock()
        } operation: {
            // Ephemeral: fuzz fresh in memory and never touch disk. Without this
            // the engine would auto-detect a saved corpus and replay only the
            // saved entries — defeating the point of measuring uncontrolled
            // non-determinism — and would also leave a corpus file behind.
            let result = try await fuzz(
                duration: .seconds(3),
                persistence: .ephemeral,
                coverageStrategy: .pathTrie
            ) { (input: ConstantPollerInput) in
                let poller = GenericTimerPoller(defaultInterval: .microseconds(100))
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await executeLane(input.lane1, on: poller) }
                    group.addTask { await executeLane(input.lane2, on: poller) }
                }
            }

            let corpusCount = result.corpus.entries.count
            print("Uncontrolled constant input: \(result.stats.totalInputs) iterations, \(corpusCount) corpus entries")

            // Without schedule control, OS scheduling non-determinism means the
            // same input produces different pathTrie paths on different runs.
            // The main sources of variation here are teardown timing (deinit
            // sometimes runs within the iteration window) and first-iteration
            // one-shot metadata cache-miss edges. Actor-isolated method calls
            // themselves share PCs across lanes and run atomically, so
            // interleaving the two lanes doesn't produce edge variation.
            #expect(
                corpusCount > 1,
                "Expected >1 corpus entries from scheduling non-determinism, got \(corpusCount)"
            )
        }
    }

    @Test("Controlled: constant input with schedule fuzzing produces reproducible entries",
          .timeLimit(.minutes(1)))
    func controlledConstantInputReproducible() async throws {
        try await withDependencies {
            $0.continuousClock = ImmediateClock()
        } operation: {
            // Ephemeral: measure fresh fuzzing behavior in memory, never replaying
            // a saved corpus or leaving one behind.
            let result = try await fuzz(
                duration: .seconds(2),
                persistence: .ephemeral,
                coverageStrategy: .pathTrie,
                scheduleFuzzing: true
            ) { (input: ConstantPollerInput) in
                let poller = GenericTimerPoller(defaultInterval: .microseconds(100))
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await executeLane(input.lane1, on: poller) }
                    group.addTask { await executeLane(input.lane2, on: poller) }
                }
            }

            let corpusCount = result.corpus.entries.count
            print("Controlled constant input: \(result.stats.totalInputs) iterations, \(corpusCount) corpus entries")

            // With schedule fuzzing, different schedule bytes explore different
            // interleavings, so we still expect multiple corpus entries.
            #expect(
                corpusCount > 1,
                "Expected >1 corpus entries from schedule exploration, got \(corpusCount)"
            )

            // Verify reproducibility: replay each corpus entry TWICE with its
            // saved schedule bytes and confirm both replays produce identical
            // coverage. We compare replay-vs-replay (not original-vs-replay)
            // because the fuzz engine uses CoverageInheritance (task-local) while
            // replay uses g_target_context (thread-local), which capture
            // slightly different edge sets.
            let replayCtx = SanCovCounters.beginMeasurement()

            var reproducible = 0
            var nonReproducible = 0

            for entry in result.corpus.entries {
                guard let scheduleBytes = entry.scheduleBytes else {
                    nonReproducible += 1
                    continue
                }

                // Replay 1
                SanCovCounters.resetCoverage(replayCtx)
                try await ScheduleController.run(
                    scheduleBytes: scheduleBytes,
                    coverageContext: replayCtx.rawContext
                ) {
                    let poller = GenericTimerPoller(defaultInterval: .microseconds(100))
                    await withTaskGroup(of: Void.self) { group in
                        group.addTask { await executeLane(entry.input.lane1, on: poller) }
                        group.addTask { await executeLane(entry.input.lane2, on: poller) }
                    }
                }
                let replay1 = try SanCovCounters.snapshotCoveredArrays(with: replayCtx)

                // Replay 2
                SanCovCounters.resetCoverage(replayCtx)
                try await ScheduleController.run(
                    scheduleBytes: scheduleBytes,
                    coverageContext: replayCtx.rawContext
                ) {
                    let poller = GenericTimerPoller(defaultInterval: .microseconds(100))
                    await withTaskGroup(of: Void.self) { group in
                        group.addTask { await executeLane(entry.input.lane1, on: poller) }
                        group.addTask { await executeLane(entry.input.lane2, on: poller) }
                    }
                }
                let replay2 = try SanCovCounters.snapshotCoveredArrays(with: replayCtx)

                let set1 = Set(replay1.indices)
                let set2 = Set(replay2.indices)

                if set1 == set2 {
                    reproducible += 1
                } else {
                    nonReproducible += 1
                    if nonReproducible <= 2 {
                        let missing = set1.subtracting(set2)
                        let extra = set2.subtracting(set1)
                        print("Non-reproducible: replay1 \(replay1.count) edges, replay2 \(replay2.count) edges")
                        print("  only in replay1: \(missing.count), only in replay2: \(extra.count)")
                    }
                }
            }

            SanCovCounters.endMeasurement(replayCtx)

            print("Reproducibility: \(reproducible)/\(corpusCount) reproducible, \(nonReproducible) non-reproducible")

            #expect(
                reproducible == corpusCount,
                "All \(corpusCount) corpus entries should be reproducible, but \(nonReproducible) were not"
            )
        }
    }

    @Test("Poller deinits when all external references are dropped")
    func pollerDoesNotLeak() async throws {
        let deinited = Mutex(false)
        let testClock = TestClock()

        await withDependencies {
            $0.continuousClock = testClock
        } operation: {
            var poller: GenericTimerPoller? = GenericTimerPoller(defaultInterval: .seconds(1))
            await poller?.onDeinit { deinited.withLock { $0 = true } }
            var subscription: TaskCancellable? = await poller?.subscribe { }
            await poller?.startPolling()

            // Wait for the first handler call — startPolling fires an immediate
            // Task { await callHandlers() } which yields to the stream.
            let stream = await poller!.stream
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next()

            // Drop our external reference — timer task holds strong self via guard-let
            poller = nil

            #expect(!deinited.withLock { $0 }, "Poller should be alive — timer task holds strong self")

            // Cancel the subscription → finish aliveStream → removeSubscriber → cancel timerTask
            subscription?.cancel()
            subscription = nil

            // Give the actor time to process removeSubscriber and release the timer task
            try? await Task.sleep(for: .milliseconds(100))

            #expect(deinited.withLock { $0 }, "Poller should deinit after subscription cancelled")
        }
    }
}

// MARK: - Lane Executor

/// Executes a sequence of operations on the poller, maintaining per-lane subscription state.
/// Each lane tracks its own subscriptions independently — when the lane ends,
/// all remaining subscription tasks are cancelled.
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
    // Cancel remaining subscriptions when lane ends
    for sub in subs { sub.cancel() }
}
