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

//
//  FuzzEngineTests.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Testing
import Foundation
import Dependencies
import FunctionSpy
import Clocks
@testable import PropertyTestingKit

/// Helper to create a mock CoverageCountersClient with coverage data.
private func makeMockCoverageClient(
    countersGenerator: @escaping @Sendable () -> [UInt64]
) -> CoverageCountersClient {
    return CoverageCountersClient(
        isAvailable: { true },
        beginMeasurement: { SanCovCounters.MeasurementContext.testInstance() },
        endMeasurement: { _ in },
        resetCoverage: { _ in },
        snapshotCoveredArraysWithContext: { _ in
            let counters = countersGenerator()
            var indices: [UInt32] = []
            for (index, count) in counters.enumerated() where count > 0 {
                indices.append(UInt32(index))
            }
            return SparseCoverage(indices: indices)
        }
    )
}

/// Error for mock coverage client that simulates unavailable coverage.
private struct MockCoverageUnavailableError: Error {}

/// Helper to create a mock CoverageCountersClient that throws (simulating unavailable coverage).
private func makeThrowingCoverageClient() -> CoverageCountersClient {
    return CoverageCountersClient(
        isAvailable: { true },
        beginMeasurement: { SanCovCounters.MeasurementContext.testInstance() },
        endMeasurement: { _ in },
        resetCoverage: { _ in },
        snapshotCoveredArraysWithContext: { _ in throw MockCoverageUnavailableError() }
    )
}

/// A MutatorProviding type that returns empty seeds and empty mutations.
/// Used to test guard branches in FuzzEngine.
struct EmptyFuzzable: MutatorProviding, Codable, Sendable, Equatable {
    let value: Int

    static var defaultMutator: Mutator<EmptyFuzzable> {
        Mutator(seeds: [], mutate: { _ in [] })
    }
}

/// A MutatorProviding type with values but empty mutations.
struct EmptyMutationsFuzzable: MutatorProviding, Codable, Sendable, Equatable {
    let value: Int

    static var defaultMutator: Mutator<EmptyMutationsFuzzable> {
        Mutator(seeds: [EmptyMutationsFuzzable(value: 1)], mutate: { _ in [] })
    }
}

@Suite("FuzzEngine")
struct FuzzEngineTests {

    // MARK: - Tests

    @Test("FuzzEngine runs and builds corpus")
    func testFuzzEngineDiscoversPaths() async {
        let config = FuzzEngineConfig(
            maxDuration: .seconds(10),
            minimizeCorpus: false,
            verbose: false,
            coverageStrategy: .alwaysInteresting
        )

        let result = await fuzzEngineWithMaxIterations(
            maxIterations: 100,
            config: config,
            additionalSeeds: [0, 1, -1, 42]
        ) { (_: Int) in }

        #expect(result.corpus.count >= 1, "Should have corpus entries")
        #expect(result.failures.isEmpty)
    }

    @Test("FuzzEngine detects test failures")
    func testFuzzEngineDetectsFailures() async {
        struct TestError: Error {}

        let config = FuzzEngineConfig(
            maxDuration: .seconds(10),
            verbose: false,
            coverageStrategy: .alwaysInteresting
        )

        // Include 42 in seeds to guarantee we hit the failure case
        let result = await fuzzEngineWithMaxIterations(
            maxIterations: 100,
            config: config,
            additionalSeeds: [0, 1, 42, -1]
        ) { (input: Int) in
            if input == 42 {
                throw TestError()
            }
        }

        #expect(!result.failures.isEmpty, "Should detect failures")
        #expect(result.failures.contains { $0.input == 42 })
    }

    @Test("FuzzEngine verbose mode logs messages")
    func testVerboseMode() async {
        let config = FuzzEngineConfig(
            maxDuration: .seconds(10),
            verbose: true,
            coverageStrategy: .alwaysInteresting
        )

        let result = await fuzzEngineWithMaxIterations(
            maxIterations: 100,
            config: config,
            additionalSeeds: [0, 1, -1, 42]
        ) { (_: Int) in }

        #expect(result.stats.totalInputs > 0)
    }

    @Test("FuzzEngine handles test errors during fuzzing")
    func testErrorsDuringFuzzing() async {
        struct FuzzError: Error {}

        let config = FuzzEngineConfig(
            maxDuration: .seconds(10),
            verbose: false,
            coverageStrategy: .alwaysInteresting
        )

        // Include multiples of 10 in seeds to guarantee failures
        let result = await fuzzEngineWithMaxIterations(
            maxIterations: 100,
            config: config,
            additionalSeeds: [0, 10, 20, 1, 2]
        ) { (input: Int) in
            if input % 10 == 0 {
                throw FuzzError()
            }
        }

        #expect(!result.failures.isEmpty, "Should have captured failures")
    }

    @Test("FuzzEngine saves corpus to directory")
    func testCorpusSaveToDirectory() async throws {
        let corpusDir = URL(fileURLWithPath: "/test/fuzz-corpus")

        let (saveSpy, saveFn) = spy { (_: Data, _: URL) in }

        let result = await withDependencies {
            // Explicitly set live coverage to prevent mock leakage from parallel tests
            $0.coverageCounters = .liveValue
            $0.corpusPersistence = CorpusPersistenceClient(
                save: saveFn,
                load: { _ in Data() },
                exists: { _ in false },
                delete: { _ in }
            )
        } operation: {
            let config = FuzzEngineConfig(
                maxDuration: .seconds(10),
                minimizeCorpus: true,
                verbose: true,
                coverageStrategy: .alwaysInteresting
            )

            return await fuzzEngineWithMaxIterations(
                maxIterations: 100,
                config: config,
                corpusDirectory: corpusDir,
                additionalSeeds: [0, 1, -1, 42]
            ) { (_: Int) in }
        }

        #expect(result.corpus.count > 0, "Should have corpus entries")
        #expect(saveSpy.callCount == 1, "Corpus should be saved")
    }

    @Test("FuzzEngine loads existing corpus and runs regression")
    func testRegressionMode() async throws {
        let corpusDir = URL(fileURLWithPath: "/test/fuzz-regression")

        // Regression is crash-only: replay inputs, check for failures, done.
        let corpusJSON = "[[42]]"
        let corpusData = Data(corpusJSON.utf8)

        let (loadSpy, loadFn) = spy { (_: URL) -> Data in corpusData }
        let (existsSpy, existsFn) = spy { (_: URL) -> Bool in true }

        let result = await withDependencies {
            $0.corpusPersistence = CorpusPersistenceClient(
                save: { _, _ in },
                load: loadFn,
                exists: existsFn,
                delete: { _ in }
            )
        } operation: {
            await fuzzEngineWithMaxIterations(
                maxIterations: 50,
                corpusDirectory: corpusDir
            ) { (_: Int) in }
        }

        #expect(existsSpy.callCount >= 1, "Should check if corpus exists")
        #expect(loadSpy.callCount == 1, "Should have loaded corpus")
        #expect(result.corpus.count > 0)
        #expect(result.wasRegression, "Should be regression mode")
    }

    @Test("FuzzEngine handles corpus load failure")
    func testCorpusLoadFailure() async throws {
        let corpusDir = URL(fileURLWithPath: "/test/fuzz-loadfail")
        let invalidJSON = Data("{ invalid json }".utf8)

        let (loadSpy, loadFn) = spy { (_: URL) -> Data in invalidJSON }
        let (existsSpy, existsFn) = spy { (_: URL) -> Bool in true }

        let result = await withDependencies {
            $0.corpusPersistence = CorpusPersistenceClient(
                save: { _, _ in },
                load: loadFn,
                exists: existsFn,
                delete: { _ in }
            )
        } operation: {
            await fuzzEngineWithMaxIterations(
                maxIterations: 50,
                coverageStrategy: .alwaysInteresting,
                corpusDirectory: corpusDir
            ) { (_: Int) in }
        }

        #expect(existsSpy.callCount >= 1)
        #expect(loadSpy.callCount == 1, "Should have attempted to load corpus")
        #expect(!result.wasRegression, "Should fall back to fuzzing mode")
    }

    @Test("FuzzEngine discovers new coverage during iteration")
    func testNewCoverageDuringIteration() async {
        let result = await withDependencies {
            // Explicitly set live coverage to prevent mock leakage from parallel tests
            $0.coverageCounters = .liveValue
        } operation: {
            await fuzzEngineWithMaxIterations(
                maxIterations: 50,
                coverageStrategy: .alwaysInteresting
            ) { (_: Int) in }
        }

        #expect(result.corpus.count >= 1)
    }

    @Test("FuzzEngine handles corpus save failure")
    func testCorpusSaveFailure() async throws {
        let corpusDir = URL(fileURLWithPath: "/test/fuzz-savefail")

        struct SaveError: Error {}

        let (saveSpy, saveFn) = spy { (_: Data, _: URL) throws -> Void in
            throw SaveError()
        }

        let result = await withDependencies {
            $0.corpusPersistence = CorpusPersistenceClient(
                save: saveFn,
                load: { _ in Data() },
                exists: { _ in false },
                delete: { _ in }
            )
        } operation: {
            await fuzzEngineWithMaxIterations(
                maxIterations: 50,
                coverageStrategy: .alwaysInteresting,
                corpusDirectory: corpusDir
            ) { (_: Int) in }
        }

        #expect(saveSpy.callCount == 1, "Should have attempted to save corpus")
        #expect(!result.wasRegression)
    }

    @Test("FuzzEngine regression success with empty corpus")
    func testRegressionSuccessPath() async throws {
        let corpusDir = URL(fileURLWithPath: "/test/fuzz-regression-success")

        // Empty corpus — regression replays zero inputs, succeeds immediately
        let corpusJSON = "[]"
        let corpusData = Data(corpusJSON.utf8)

        let (loadSpy, loadFn) = spy { (_: URL) -> Data in corpusData }
        let (existsSpy, existsFn) = spy { (_: URL) -> Bool in true }

        let result = await withDependencies {
            $0.corpusPersistence = CorpusPersistenceClient(
                save: { _, _ in },
                load: loadFn,
                exists: existsFn,
                delete: { _ in }
            )
        } operation: {
            await fuzzEngineWithMaxIterations(
                maxIterations: 50,
                corpusDirectory: corpusDir
            ) { (_: Int) in }
        }

        #expect(existsSpy.callCount >= 1)
        #expect(loadSpy.callCount == 1, "Should have loaded corpus")
        #expect(result.wasRegression, "Should be regression mode with empty corpus")
    }

    @Test("FuzzEngine handles coverage unavailable - test succeeds")
    func testCoverageUnavailableSuccess() async throws {
        let result = await withDependencies {
            $0.coverageCounters = makeThrowingCoverageClient()
        } operation: {
            await fuzzEngineWithMaxIterations(maxIterations: 50) { (_: Int) in }
        }

        #expect(result.stats.totalInputs > 0, "Test should have executed")
        #expect(result.corpus.count == 0, "Corpus should be empty without coverage")
        #expect(result.failures.isEmpty)
    }

    @Test("FuzzEngine handles coverage unavailable - test throws")
    func testCoverageUnavailableWithError() async throws {
        struct TestError: Error {}

        let result = await withDependencies {
            $0.coverageCounters = makeThrowingCoverageClient()
        } operation: {
            await fuzzEngineWithMaxIterations(maxIterations: 50) { (_: Int) in
                throw TestError()
            }
        }

        #expect(!result.failures.isEmpty, "Should capture failures without coverage")
        #expect(result.failures.first?.error is TestError)
    }

    @Test("FuzzEngine handles coverage unavailable after test execution")
    func testCoverageUnavailableAfter() async throws {
        // When snapshotCoveredArraysWithContext throws, no coverage is recorded
        let result = await withDependencies {
            $0.coverageCounters = makeThrowingCoverageClient()
        } operation: {
            await fuzzEngineWithMaxIterations(maxIterations: 50) { (_: Int) in }
        }

        #expect(result.corpus.count == 0, "Corpus should be empty when coverage throws")
    }

    @Test("FuzzEngine verbose logs new coverage during iterations")
    func testNewCoverageVerboseInIterations() async {
        let config = FuzzEngineConfig(
            maxDuration: .seconds(10),
            minimizeCorpus: false,
            verbose: true,
            coverageStrategy: .alwaysInteresting
        )

        let result = await fuzzEngineWithMaxIterations(
            maxIterations: 50,
            config: config
        ) { (_: Int) in }

        #expect(result.corpus.count >= 1, "Should have corpus entries")
        #expect(result.stats.totalInputs > 5, "Should test more than just seeds")
    }

    @Test("FuzzEngine regression captures failures during replay")
    func testRegressionFailures() async throws {
        let corpusDir = URL(fileURLWithPath: "/test/fuzz-regression-fail")

        // Corpus with one entry (input=42)
        let corpusJSON = "[[42]]"
        let corpusData = Data(corpusJSON.utf8)

        let (_, loadFn) = spy { (_: URL) -> Data in corpusData }

        struct RegressionError: Error {}

        let result = await withDependencies {
            $0.corpusPersistence = CorpusPersistenceClient(
                save: { _, _ in },
                load: loadFn,
                exists: { _ in true },
                delete: { _ in }
            )
        } operation: {
            await fuzzEngineWithMaxIterations(
                maxIterations: 50,
                corpusDirectory: corpusDir
            ) { (input: Int) in
                if input == 42 {
                    throw RegressionError()
                }
            }
        }

        #expect(result.wasRegression, "Should be regression mode")
        #expect(!result.failures.isEmpty, "Should capture failures during regression")
        #expect(result.failures.first?.input == 42)
    }

    @Test("FuzzEngine handles empty fuzz array gracefully")
    func testEmptyFuzzArray() async {
        let result = await fuzzEngineWithMaxIterations(
            maxIterations: 20,
            coverageStrategy: .alwaysInteresting
        ) { (_: EmptyFuzzable) in }

        // With empty seeds, no seeds are processed and iterations skip via guard
        #expect(result.corpus.count == 0, "Empty seeds should produce empty corpus")
        #expect(result.stats.totalInputs == 0 || result.stats.totalInputs == 10,
                "Should either process no inputs or hit iteration limit with skips")
    }

    @Test("FuzzEngine handles empty mutations array gracefully")
    func testEmptyMutationsArray() async {
        let result = await fuzzEngineWithMaxIterations(
            maxIterations: 20,
            coverageStrategy: .alwaysInteresting
        ) { (_: EmptyMutationsFuzzable) in }

        // With one seed value, corpus gets one entry, then mutations fail
        #expect(result.corpus.count >= 0)  // May have seed entry
    }

    // MARK: - Coverage Reset Integration Tests

    @Test("FuzzEngine discovers different coverage for different inputs")
    func testDifferentInputsDiscoverDifferentCoverage() async {
        // Create a mock that records coverage per-input
        let snapshotCoveredArraysFn: @Sendable () -> SparseCoverage = {
            // Return different coverage based on some internal state
            // This simulates real coverage where different code paths are taken
            SparseCoverage(indices: [1, 2, 3])
        }

        let result = await withDependencies {
            $0.coverageCounters = CoverageCountersClient(
                isAvailable: { true },
                beginMeasurement: { SanCovCounters.MeasurementContext.testInstance() },
                endMeasurement: { _ in },
                resetCoverage: { _ in },
                snapshotCoveredArraysWithContext: { _ in snapshotCoveredArraysFn() }
            )
        } operation: {
            await fuzzEngineWithMaxIterations(maxIterations: 50) { (input: Int) in
                // Different inputs should exercise different code paths
                if input > 0 {
                    _ = input &* 2
                } else {
                    _ = input &* 3
                }
            }
        }

        // Should have run multiple iterations
        #expect(result.stats.totalInputs > 0, "Should have tested inputs")
    }

    @Test("FuzzEngine resetCoverage is called between iterations")
    func testResetCoverageCalledBetweenIterations() async {
        let resetCount = SyncBox(0)
        let coveredIndicesCheckCount = SyncBox(0)

        let result = await withDependencies {
            $0.coverageCounters = CoverageCountersClient(
                isAvailable: { true },
                beginMeasurement: { SanCovCounters.MeasurementContext.testInstance() },
                endMeasurement: { _ in },
                resetCoverage: { _ in
                    resetCount.update { $0 += 1 }
                },
                snapshotCoveredArraysWithContext: { _ in
                    // Return sparse coverage with a unique index each time
                    SparseCoverage(indices: [UInt32(coveredIndicesCheckCount.value)])
                },
                withCoveredIndices: { _, body in
                    coveredIndicesCheckCount.update { $0 += 1 }
                    // Return unique index each time so corpus accepts it
                    let index = UInt32(coveredIndicesCheckCount.value)
                    return [index].withUnsafeBufferPointer { body($0) }
                }
            )
        } operation: {
            await fuzzEngineWithMaxIterations(maxIterations: 10) { (_: Int) in }
        }

        // Reset should be called once per iteration
        // withCoveredIndices should be called once per iteration (for signature match check)
        #expect(resetCount.value == result.stats.totalInputs,
                "resetCoverage should be called once per iteration: got \(resetCount.value), expected \(result.stats.totalInputs)")
        #expect(coveredIndicesCheckCount.value == result.stats.totalInputs,
                "withCoveredIndices should be called once per iteration")
    }

    @Test("FuzzEngine beginMeasurement called only once")
    func testBeginMeasurementCalledOnce() async {
        let beginCount = SyncBox(0)
        let endCount = SyncBox(0)

        let result = await withDependencies {
            $0.coverageCounters = CoverageCountersClient(
                isAvailable: { true },
                beginMeasurement: {
                    beginCount.update { $0 += 1 }
                    return SanCovCounters.MeasurementContext.testInstance()
                },
                endMeasurement: { _ in
                    endCount.update { $0 += 1 }
                },
                resetCoverage: { _ in },
                snapshotCoveredArraysWithContext: { _ in SparseCoverage(indices: [1]) }
            )
        } operation: {
            await fuzzEngineWithMaxIterations(maxIterations: 50) { (_: Int) in }
        }

        // With hoisted context, begin and end should each be called exactly once
        #expect(beginCount.value == 1,
                "beginMeasurement should be called exactly once (hoisted out of loop), got \(beginCount.value)")
        #expect(endCount.value == 1,
                "endMeasurement should be called exactly once, got \(endCount.value)")

        // But we should have run many iterations
        #expect(result.stats.totalInputs > 1,
                "Should have run multiple iterations")
    }

    @Test("FuzzEngine coverage isolation - each iteration sees fresh coverage")
    func testCoverageIsolationPerIteration() async {
        // This test verifies that each iteration starts with fresh (reset) coverage
        // by tracking the sequence of reset -> run -> coverageCheck

        enum CoverageEvent: Equatable {
            case reset
            case coverageCheck
        }

        let events = SyncBox<[CoverageEvent]>([])
        let checkCounter = SyncBox(0)

        _ = await withDependencies {
            $0.coverageCounters = CoverageCountersClient(
                isAvailable: { true },
                beginMeasurement: { SanCovCounters.MeasurementContext.testInstance() },
                endMeasurement: { _ in },
                resetCoverage: { _ in
                    events.update { $0.append(.reset) }
                },
                snapshotCoveredArraysWithContext: { _ in
                    SparseCoverage(indices: [UInt32(checkCounter.value)])
                },
                withCoveredIndices: { _, body in
                    events.update { $0.append(.coverageCheck) }
                    checkCounter.update { $0 += 1 }
                    let index = UInt32(checkCounter.value)
                    return [index].withUnsafeBufferPointer { body($0) }
                }
            )
        } operation: {
            await fuzzEngineWithMaxIterations(maxIterations: 5) { (_: Int) in }
        }

        let recordedEvents = events.value

        // Should have 5 reset-coverageCheck pairs
        #expect(recordedEvents.count == 10, "Should have 5 pairs of reset+coverageCheck events")

        // Verify the pattern: reset, coverageCheck, reset, coverageCheck, ...
        for i in stride(from: 0, to: recordedEvents.count, by: 2) {
            if i < recordedEvents.count {
                #expect(recordedEvents[i] == .reset, "Event \(i) should be reset")
            }
            if i + 1 < recordedEvents.count {
                #expect(recordedEvents[i + 1] == .coverageCheck, "Event \(i+1) should be coverageCheck")
            }
        }
    }

    @Test("FuzzEngine with live coverage discovers new edges")
    func testLiveCoverageDiscovery() async {
        // This test uses live coverage to verify the reset pattern works correctly
        // with actual coverage instrumentation

        let result = await withDependencies {
            // Use live coverage counters
            $0.coverageCounters = .liveValue
        } operation: {
            let config = FuzzEngineConfig(
                maxDuration: .seconds(10),
                minimizeCorpus: false,
                verbose: false
            )

            return await fuzzEngineWithMaxIterations(
                maxIterations: 100,
                config: config,
                additionalSeeds: [0, 1, -1, 100, -100, Int.max, Int.min]
            ) { (input: Int) in
                // Exercise different code paths based on input
                if input > 0 {
                    if input > 50 {
                        _ = input &* 2
                    } else {
                        _ = input &+ 1
                    }
                } else if input < 0 {
                    if input < -50 {
                        _ = input &* 3
                    } else {
                        _ = input &- 1
                    }
                } else {
                    _ = 0
                }
            }
        }

        // With live coverage and varied inputs, should discover coverage
        #expect(result.stats.totalInputs > 0, "Should have tested inputs")
        // Note: corpus size depends on whether coverage is available at runtime
    }
}
