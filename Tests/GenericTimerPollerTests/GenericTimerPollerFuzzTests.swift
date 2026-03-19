//
//  GenericTimerPollerFuzzTests.swift
//  GenericTimerPollerTests
//
//  Fuzz test for GenericTimerPoller to find continuation misuse crashes.
//  Generates concurrent operation sequences and runs them against the poller.
//

import Clocks
@preconcurrency import Combine
import Dependencies
import Foundation
import GenericTimerPoller
@testable import PropertyTestingKit
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
            mutate: { input in
                var mutations: [PollerFuzzInput] = []
                let ops = PollerOp.allCases

                // Flip a single op in lane1
                for i in input.lane1.indices {
                    var copy = input
                    let replacement = ops[Int(copy.lane1[i].rawValue + 1) % ops.count]
                    copy.lane1[i] = replacement
                    mutations.append(copy)
                }
                // Flip a single op in lane2
                for i in input.lane2.indices {
                    var copy = input
                    let replacement = ops[Int(copy.lane2[i].rawValue + 1) % ops.count]
                    copy.lane2[i] = replacement
                    mutations.append(copy)
                }

                // Append an op to each lane
                for op in ops {
                    var copy1 = input
                    copy1.lane1.append(op)
                    mutations.append(copy1)

                    var copy2 = input
                    copy2.lane2.append(op)
                    mutations.append(copy2)
                }

                // Remove an op from each lane
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

                return mutations
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

// MARK: - Fuzz Test

@Suite("GenericTimerPoller Fuzz Tests")
struct GenericTimerPollerFuzzTests {

    @Test("Concurrent operations don't crash")
    func fuzzConcurrentOperations() async throws {
        try await withDependencies {
            $0.continuousClock = ImmediateClock()
        } operation: {
            try await fuzz(
                duration: .seconds(30)
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
        }
    }
}

// MARK: - Lane Executor

/// Executes a sequence of operations on the poller, maintaining per-lane subscription state.
/// Each lane tracks its own subscriptions independently — when the lane ends,
/// all subscriptions deinit, firing their cancel closures (which race with the other lane).
private func executeLane(_ ops: [PollerOp], on poller: GenericTimerPoller) async {
    var subs: [AnyCancellable] = []

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
    // subs deinit here — cancel closures fire, racing with the other lane
}
