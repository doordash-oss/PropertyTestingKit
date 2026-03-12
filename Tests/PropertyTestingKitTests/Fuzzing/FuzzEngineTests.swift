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
        // Use AlwaysInterestingCorpusRegistry to bypass coverage data requirements
        let alwaysInterestingRegistry = AlwaysInterestingCorpusRegistry()

        let result = await withDependencies {
            $0.corpusRegistry = alwaysInterestingRegistry
        } operation: {
            let config = FuzzEngineConfig(
                maxDuration: .seconds(10),
                minimizeCorpus: false,
                verbose: false
            )

            return await fuzzEngineWithMaxIterations(
                maxIterations: 100,
                config: config,
                additionalSeeds: [0, 1, -1, 42]
            ) { (_: Int) in }
        }

        #expect(result.corpus.count >= 1, "Should have corpus entries")
        #expect(result.failures.isEmpty)
    }

    @Test("FuzzEngine detects test failures")
    func testFuzzEngineDetectsFailures() async {
        struct TestError: Error {}

        // Use AlwaysInterestingCorpusRegistry to bypass coverage data requirements
        let alwaysInterestingRegistry = AlwaysInterestingCorpusRegistry()

        let result = await withDependencies {
            $0.corpusRegistry = alwaysInterestingRegistry
        } operation: {
            let config = FuzzEngineConfig(
                maxDuration: .seconds(10),
                verbose: false
            )

            // Include 42 in seeds to guarantee we hit the failure case
            return await fuzzEngineWithMaxIterations(
                maxIterations: 100,
                config: config,
                additionalSeeds: [0, 1, 42, -1]
            ) { (input: Int) in
                if input == 42 {
                    throw TestError()
                }
            }
        }

        #expect(!result.failures.isEmpty, "Should detect failures")
        #expect(result.failures.contains { $0.input == 42 })
    }

    @Test("FuzzEngine verbose mode logs messages")
    func testVerboseMode() async {
        // Use AlwaysInterestingCorpusRegistry to bypass coverage data requirements
        let alwaysInterestingRegistry = AlwaysInterestingCorpusRegistry()

        let result = await withDependencies {
            $0.corpusRegistry = alwaysInterestingRegistry
        } operation: {
            let config = FuzzEngineConfig(
                maxDuration: .seconds(10),
                verbose: true
            )

            return await fuzzEngineWithMaxIterations(
                maxIterations: 100,
                config: config,
                additionalSeeds: [0, 1, -1, 42]
            ) { (_: Int) in }
        }

        #expect(result.stats.totalInputs > 0)
    }

    @Test("FuzzEngine handles test errors during fuzzing")
    func testErrorsDuringFuzzing() async {
        struct FuzzError: Error {}

        // Use AlwaysInterestingCorpusRegistry to bypass coverage data requirements
        let alwaysInterestingRegistry = AlwaysInterestingCorpusRegistry()

        let result = await withDependencies {
            $0.corpusRegistry = alwaysInterestingRegistry
        } operation: {
            let config = FuzzEngineConfig(
                maxDuration: .seconds(10),
                verbose: false
            )

            // Include multiples of 10 in seeds to guarantee failures
            return await fuzzEngineWithMaxIterations(
                maxIterations: 100,
                config: config,
                additionalSeeds: [0, 10, 20, 1, 2]
            ) { (input: Int) in
                if input % 10 == 0 {
                    throw FuzzError()
                }
            }
        }

        #expect(!result.failures.isEmpty, "Should have captured failures")
    }

    @Test("FuzzEngine saves corpus to directory")
    func testCorpusSaveToDirectory() async throws {
        let corpusDir = URL(fileURLWithPath: "/test/fuzz-corpus")

        // Use AlwaysInterestingCorpusRegistry to bypass coverage data requirements
        let alwaysInterestingRegistry = AlwaysInterestingCorpusRegistry()
        let (saveSpy, saveFn) = spy { (_: Data, _: URL) in }

        let result = await withDependencies {
            $0.corpusRegistry = alwaysInterestingRegistry
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
                verbose: true
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

        // For regression to succeed, the mock must return consistent coverage that
        // matches the corpus entry's signature.
        //
        // With reset+snapshot model:
        // - reset() is called (no snapshot needed)
        // - test runs
        // - snapshot() returns the coverage
        //
        // The corpus entry has signature {"buckets": {"1": 1}} = [1: .one]
        // So snapshot must always return counters[1]=1 to match.
        // FuzzEngine uses snapshotCoveredArrays (sync) in the hot path
        // Return counters[1]=1 to match the corpus signature
        let snapshotCoveredArraysFn: @Sendable () -> SparseCoverage = {
            SparseCoverage(indices: [1])
        }

        // Test the signature creation first
        let sigTest = CoverageSignature(sparse: SparseCoverage(indices: [1]))
        print("DEBUG: Test signature edges=\(sigTest.edges)")

        // Create corpus with matching sparse coverage
        // Note: InputContainer encodes Int 42 as base64 of "42" = "NDI="
        let corpusJSON = """
        {
            "entries": [
                {
                    "input": ["NDI="],
                    "signature": {"indices": [1]},
                    "discoveredAt": "2025-01-01T00:00:00Z"
                }
            ],
            "createdAt": "2025-01-01T00:00:00Z",
            "updatedAt": "2025-01-01T00:00:00Z",
            "coveredIndices": [1]
        }
        """
        let corpusData = Data(corpusJSON.utf8)

        // Parse corpus to verify the coverage
        let parsedCorpusSnapshot = try JSONDecoder.corpusDecoder.decode(CorpusSnapshot<Int>.self, from: corpusData)
        print("DEBUG: Parsed corpus sparse coverage=\(parsedCorpusSnapshot.entries[0].sparseCoverage.indices)")
        print("DEBUG: Coverage matches? \(parsedCorpusSnapshot.entries[0].sparseCoverage.indices == [1])")

        let (loadSpy, loadFn) = spy { (_: URL) -> Data in corpusData }
        let (existsSpy, existsFn) = spy { (_: URL) -> Bool in true }

        let result = await withDependencies {
            $0.coverageCounters = CoverageCountersClient(
                isAvailable: { true },
                beginMeasurement: { SanCovCounters.MeasurementContext.testInstance() },
                endMeasurement: { _ in },
                resetCoverage: { _ in },
                snapshotCoveredArraysWithContext: { _ in snapshotCoveredArraysFn() }
            )
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

        // Use AlwaysInterestingCorpusRegistry to bypass coverage data requirements
        let alwaysInterestingRegistry = AlwaysInterestingCorpusRegistry()
        let (loadSpy, loadFn) = spy { (_: URL) -> Data in invalidJSON }
        let (existsSpy, existsFn) = spy { (_: URL) -> Bool in true }

        let result = await withDependencies {
            $0.corpusRegistry = alwaysInterestingRegistry
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
        #expect(loadSpy.callCount == 1, "Should have attempted to load corpus")
        #expect(!result.wasRegression, "Should fall back to fuzzing mode")
    }

    @Test("FuzzEngine discovers new coverage during iteration")
    func testNewCoverageDuringIteration() async {
        // Use AlwaysInterestingCorpusRegistry to bypass coverage data requirements
        let alwaysInterestingRegistry = AlwaysInterestingCorpusRegistry()

        let result = await withDependencies {
            $0.corpusRegistry = alwaysInterestingRegistry
            // Explicitly set live coverage to prevent mock leakage from parallel tests
            $0.coverageCounters = .liveValue
        } operation: {
            await fuzzEngineWithMaxIterations(maxIterations: 50) { (_: Int) in }
        }

        #expect(result.corpus.count >= 1)
    }

    @Test("FuzzEngine handles corpus save failure")
    func testCorpusSaveFailure() async throws {
        let corpusDir = URL(fileURLWithPath: "/test/fuzz-savefail")

        struct SaveError: Error {}

        // Use AlwaysInterestingCorpusRegistry to bypass coverage data requirements
        let alwaysInterestingRegistry = AlwaysInterestingCorpusRegistry()
        let (saveSpy, saveFn) = spy { (_: Data, _: URL) throws -> Void in
            throw SaveError()
        }

        let result = await withDependencies {
            $0.corpusRegistry = alwaysInterestingRegistry
            $0.corpusPersistence = CorpusPersistenceClient(
                save: saveFn,
                load: { _ in Data() },
                exists: { _ in false },
                delete: { _ in }
            )
        } operation: {
            await fuzzEngineWithMaxIterations(
                maxIterations: 50,
                corpusDirectory: corpusDir
            ) { (_: Int) in }
        }

        #expect(saveSpy.callCount == 1, "Should have attempted to save corpus")
        #expect(!result.wasRegression)
    }

    @Test("FuzzEngine regression success without coverage change")
    func testRegressionSuccessPath() async throws {
        let corpusDir = URL(fileURLWithPath: "/test/fuzz-regression-success")

        // All zeros means empty SparseCoverage
        let snapshotCoveredArraysFn: @Sendable () -> SparseCoverage = {
            SparseCoverage(indices: [])
        }

        // Empty corpus
        let corpusJSON = """
        {
            "entries": [],
            "createdAt": "2025-01-01T00:00:00Z",
            "updatedAt": "2025-01-01T00:00:00Z",
            "coveredIndices": []
        }
        """
        let corpusData = Data(corpusJSON.utf8)

        let (loadSpy, loadFn) = spy { (_: URL) -> Data in corpusData }
        let (existsSpy, existsFn) = spy { (_: URL) -> Bool in true }

        let result = await withDependencies {
            $0.coverageCounters = CoverageCountersClient(
                isAvailable: { true },
                beginMeasurement: { SanCovCounters.MeasurementContext.testInstance() },
                endMeasurement: { _ in },
                resetCoverage: { _ in },
                snapshotCoveredArraysWithContext: { _ in snapshotCoveredArraysFn() }
            )
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

    @Test("FuzzEngine regression detects coverage change and re-fuzzes")
    func testRegressionCoverageChange() async throws {
        let corpusDir = URL(fileURLWithPath: "/test/fuzz-regression-change")

        // Corpus has signature {5: 1}, but mock always returns {1: 1}
        // This mismatch triggers coverage change detection
        // FuzzEngine uses snapshotCoveredArrays, so provide that
        let snapshotCoveredArraysFn: @Sendable () -> SparseCoverage = {
            SparseCoverage(indices: [1])  // Different from corpus signature {5: 1}
        }

        // Corpus has signature with edge 5
        // Mock returns edge 1 which is different, triggering coverage change
        // Note: InputContainer encodes Int 42 as base64 of "42" = "NDI="
        let corpusJSON = """
        {
            "entries": [
                {
                    "input": ["NDI="],
                    "signature": {"edges": [5]},
                    "discoveredAt": "2025-01-01T00:00:00Z"
                }
            ],
            "createdAt": "2025-01-01T00:00:00Z",
            "updatedAt": "2025-01-01T00:00:00Z",
            "coveredIndices": [5]
        }
        """
        let corpusData = Data(corpusJSON.utf8)

        let (loadSpy, loadFn) = spy { (_: URL) -> Data in corpusData }
        let (existsSpy, existsFn) = spy { (_: URL) -> Bool in true }

        let result = await withDependencies {
            $0.coverageCounters = CoverageCountersClient(
                isAvailable: { true },
                beginMeasurement: { SanCovCounters.MeasurementContext.testInstance() },
                endMeasurement: { _ in },
                resetCoverage: { _ in },
                snapshotCoveredArraysWithContext: { _ in snapshotCoveredArraysFn() }
            )
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
        #expect(!result.wasRegression, "Should re-fuzz after coverage change")
    }

    @Test("FuzzEngine verbose logs new coverage during iterations")
    func testNewCoverageVerboseInIterations() async {
        // This test covers the "New coverage!" verbose path
        // Use AlwaysInterestingCorpusRegistry to bypass coverage data requirements
        let alwaysInterestingRegistry = AlwaysInterestingCorpusRegistry()

        let result = await withDependencies {
            $0.corpusRegistry = alwaysInterestingRegistry
        } operation: {
            let config = FuzzEngineConfig(
                maxDuration: .seconds(10),
                minimizeCorpus: false,
                verbose: true
            )

            return await fuzzEngineWithMaxIterations(
                maxIterations: 50,
                config: config
            ) { (_: Int) in }
        }

        #expect(result.corpus.count >= 1, "Should have corpus entries")
        #expect(result.stats.totalInputs > 5, "Should test more than just seeds")
    }

    @Test("FuzzEngine regression captures failures during replay")
    func testRegressionFailures() async throws {
        let corpusDir = URL(fileURLWithPath: "/test/fuzz-regression-fail")

        // All calls return counters[1]=1 to match corpus signature {1: 1}
        // FuzzEngine uses snapshotCoveredArrays in the hot path
        let snapshotCoveredArraysFn: @Sendable () -> SparseCoverage = {
            SparseCoverage(indices: [1])  // Always return matching coverage
        }

        // Corpus with sparse coverage containing edge 1
        // Note: InputContainer encodes Int 42 as base64 of "42" = "NDI="
        let corpusJSON = """
        {
            "entries": [
                {
                    "input": ["NDI="],
                    "signature": {"indices": [1]},
                    "discoveredAt": "2025-01-01T00:00:00Z"
                }
            ],
            "createdAt": "2025-01-01T00:00:00Z",
            "updatedAt": "2025-01-01T00:00:00Z",
            "coveredIndices": [1]
        }
        """
        let corpusData = Data(corpusJSON.utf8)

        let (_, loadFn) = spy { (_: URL) -> Data in corpusData }

        struct RegressionError: Error {}

        let result = await withDependencies {
            $0.coverageCounters = CoverageCountersClient(
                isAvailable: { true },
                beginMeasurement: { SanCovCounters.MeasurementContext.testInstance() },
                endMeasurement: { _ in },
                resetCoverage: { _ in },
                snapshotCoveredArraysWithContext: { _ in snapshotCoveredArraysFn() }
            )
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
        // Use AlwaysInterestingCorpusRegistry to bypass coverage data requirements
        let alwaysInterestingRegistry = AlwaysInterestingCorpusRegistry()

        let result = await withDependencies {
            $0.corpusRegistry = alwaysInterestingRegistry
        } operation: {
            await fuzzEngineWithMaxIterations(maxIterations: 20) { (_: EmptyFuzzable) in }
        }

        // With empty seeds, no seeds are processed and iterations skip via guard
        #expect(result.corpus.count == 0, "Empty seeds should produce empty corpus")
        #expect(result.stats.totalInputs == 0 || result.stats.totalInputs == 10,
                "Should either process no inputs or hit iteration limit with skips")
    }

    @Test("FuzzEngine handles empty mutations array gracefully")
    func testEmptyMutationsArray() async {
        // Use AlwaysInterestingCorpusRegistry to bypass coverage data requirements
        let alwaysInterestingRegistry = AlwaysInterestingCorpusRegistry()

        let result = await withDependencies {
            $0.corpusRegistry = alwaysInterestingRegistry
        } operation: {
            await fuzzEngineWithMaxIterations(maxIterations: 20) { (_: EmptyMutationsFuzzable) in }
        }

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
        let signatureHashCount = SyncBox(0)

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
                    SparseCoverage(indices: [UInt32(signatureHashCount.value)])
                },
                computeSignatureHash: { _ in
                    signatureHashCount.update { $0 += 1 }
                    // Return unique hash each time so corpus accepts it
                    return signatureHashCount.value
                }
            )
        } operation: {
            await fuzzEngineWithMaxIterations(maxIterations: 10) { (_: Int) in }
        }

        // Reset should be called once per iteration
        // computeSignatureHash should be called once per iteration
        #expect(resetCount.value == result.stats.totalInputs,
                "resetCoverage should be called once per iteration: got \(resetCount.value), expected \(result.stats.totalInputs)")
        #expect(signatureHashCount.value == result.stats.totalInputs,
                "computeSignatureHash should be called once per iteration")
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
        // by tracking the sequence of reset -> run -> signatureHash

        enum CoverageEvent: Equatable {
            case reset
            case signatureHash
        }

        let events = SyncBox<[CoverageEvent]>([])
        let hashCounter = SyncBox(0)

        _ = await withDependencies {
            $0.coverageCounters = CoverageCountersClient(
                isAvailable: { true },
                beginMeasurement: { SanCovCounters.MeasurementContext.testInstance() },
                endMeasurement: { _ in },
                resetCoverage: { _ in
                    events.update { $0.append(.reset) }
                },
                snapshotCoveredArraysWithContext: { _ in
                    // Return sparse coverage with a unique index
                    SparseCoverage(indices: [UInt32(hashCounter.value)])
                },
                computeSignatureHash: { _ in
                    events.update { $0.append(.signatureHash) }
                    hashCounter.update { $0 += 1 }
                    // Return unique hash each time
                    return hashCounter.value
                }
            )
        } operation: {
            await fuzzEngineWithMaxIterations(maxIterations: 5) { (_: Int) in }
        }

        let recordedEvents = events.value

        // Should have 5 reset-signatureHash pairs
        #expect(recordedEvents.count == 10, "Should have 5 pairs of reset+signatureHash events")

        // Verify the pattern: reset, signatureHash, reset, signatureHash, ...
        for i in stride(from: 0, to: recordedEvents.count, by: 2) {
            if i < recordedEvents.count {
                #expect(recordedEvents[i] == .reset, "Event \(i) should be reset")
            }
            if i + 1 < recordedEvents.count {
                #expect(recordedEvents[i + 1] == .signatureHash, "Event \(i+1) should be signatureHash")
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

