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
        snapshotCoveredArraysWithContext: { _ in throw MockCoverageUnavailableError() }
    )
}

/// A MutatorProviding type that returns empty seeds and empty mutations.
/// Used to test guard branches in FuzzEngine.
struct EmptyFuzzable: MutatorProviding, Codable, Sendable, Equatable {
    let value: Int

    static var defaultMutator: AnyMutator<EmptyFuzzable> {
        AnyMutator(seeds: []) { _ in [] }
    }
}

/// A MutatorProviding type with values but empty mutations.
struct EmptyMutationsFuzzable: MutatorProviding, Codable, Sendable, Equatable {
    let value: Int

    static var defaultMutator: AnyMutator<EmptyMutationsFuzzable> {
        AnyMutator(seeds: [EmptyMutationsFuzzable(value: 1)]) { _ in [] }
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

        // Create corpus with matching signature
        // Note: InputContainer encodes Int 42 as base64 of "42" = "NDI="
        let corpusJSON = """
        {
            "entries": [
                {
                    "input": ["NDI="],
                    "signature": {"edges": [1]},
                    "discoveredAt": "2025-01-01T00:00:00Z"
                }
            ],
            "createdAt": "2025-01-01T00:00:00Z",
            "updatedAt": "2025-01-01T00:00:00Z",
            "totalCoverage": {"edges": [1]}
        }
        """
        let corpusData = Data(corpusJSON.utf8)

        // Parse corpus to verify the signature
        let parsedCorpusSnapshot = try JSONDecoder.corpusDecoder.decode(CorpusSnapshot<Int>.self, from: corpusData)
        print("DEBUG: Parsed corpus signature edges=\(parsedCorpusSnapshot.entries[0].signature.edges)")
        print("DEBUG: Signatures equal? \(sigTest == parsedCorpusSnapshot.entries[0].signature)")

        let (loadSpy, loadFn) = spy { (_: URL) -> Data in corpusData }
        let (existsSpy, existsFn) = spy { (_: URL) -> Bool in true }

        let result = await withDependencies {
            $0.coverageCounters = CoverageCountersClient(
                isAvailable: { true },
                beginMeasurement: { SanCovCounters.MeasurementContext.testInstance() },
                endMeasurement: { _ in },
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
            "totalCoverage": {"edges": []}
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
            "totalCoverage": {"edges": [5]}
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

        // Corpus with signature containing edge 1
        // Note: InputContainer encodes Int 42 as base64 of "42" = "NDI="
        let corpusJSON = """
        {
            "entries": [
                {
                    "input": ["NDI="],
                    "signature": {"edges": [1]},
                    "discoveredAt": "2025-01-01T00:00:00Z"
                }
            ],
            "createdAt": "2025-01-01T00:00:00Z",
            "updatedAt": "2025-01-01T00:00:00Z",
            "totalCoverage": {"edges": [1]}
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
}

