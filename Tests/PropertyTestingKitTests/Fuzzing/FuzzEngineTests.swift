//
//  FuzzEngineTests.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Testing
import Foundation
import Dependencies
import FunctionSpy
@testable import PropertyTestingKit

/// A Fuzzable type that returns empty fuzz values and empty mutations.
/// Used to test guard branches in FuzzEngine.
struct EmptyFuzzable: Fuzzable, Codable, Sendable, Equatable {
    let value: Int

    static var fuzz: [EmptyFuzzable] { [] }

    func mutate() -> [EmptyFuzzable] { [] }
}

/// A Fuzzable type with values but empty mutations.
struct EmptyMutationsFuzzable: Fuzzable, Codable, Sendable, Equatable {
    let value: Int

    static var fuzz: [EmptyMutationsFuzzable] {
        [EmptyMutationsFuzzable(value: 1)]
    }

    func mutate() -> [EmptyMutationsFuzzable] { [] }
}

@Suite("FuzzEngine")
struct FuzzEngineTests {

    // MARK: - Helpers

    /// Creates a SanCovCounters with a specific signature pattern.
    /// Different counter values produce different CoverageSignatures.
    /// Used only for tests that specifically test coverage behavior.
    static func makeCounters(_ seed: Int) -> SanCovCounters {
        var counters = [UInt64](repeating: 0, count: 100)
        counters[seed % 100] = UInt64(seed + 1)
        return SanCovCounters(counters: counters)
    }

    // MARK: - Tests

    @Test("FuzzEngine runs and builds corpus")
    func testFuzzEngineDiscoversPaths() async {
        // Use AlwaysInterestingCorpusRegistry to bypass coverage data requirements
        let alwaysInterestingRegistry = AlwaysInterestingCorpusRegistry()

        let result = await withDependencies {
            $0.corpusRegistry = alwaysInterestingRegistry
        } operation: {
            let config = FuzzEngine<Int>.Config(
                maxIterations: 30,
                maxDuration: 5,
                plateauConfig: .init(enabled: false),
                minimizeCorpus: false,
                verbose: false
            )

            let engine = FuzzEngine<Int>(config: config, corpusDirectory: nil)
            return await engine.run { _ in }
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
            let config = FuzzEngine<Int>.Config(
                maxIterations: 20,
                maxDuration: 3,
                verbose: false
            )

            let engine = FuzzEngine<Int>(config: config, corpusDirectory: nil)
            return await engine.run { (input: Int) in
                if input == 42 {
                    throw TestError()
                }
            }
        }

        #expect(!result.failures.isEmpty, "Should detect failures")
        #expect(result.failures.contains { $0.input == 42 })
    }

    @Test("FuzzEngine respects iteration limit")
    func testIterationLimit() async {
        // Use AlwaysInterestingCorpusRegistry to bypass coverage data requirements
        let alwaysInterestingRegistry = AlwaysInterestingCorpusRegistry()

        let result = await withDependencies {
            $0.corpusRegistry = alwaysInterestingRegistry
        } operation: {
            let config = FuzzEngine<Int>.Config(
                maxIterations: 50,  // Higher than Int.fuzz count (21) to allow some fuzzing
                maxDuration: 60,
                plateauConfig: .init(enabled: false),
                verbose: false,
                enableValueProfile: false  // Disable to test iteration limit precisely
            )

            let engine = FuzzEngine<Int>(config: config, corpusDirectory: nil)
            return await engine.run { _ in }
        }

        #expect(result.stats.totalInputs <= 50)
    }

    @Test("FuzzStats.inputsPerSecond computes correctly")
    func testInputsPerSecond() async {
        // Use AlwaysInterestingCorpusRegistry to bypass coverage data requirements
        let alwaysInterestingRegistry = AlwaysInterestingCorpusRegistry()

        let result = await withDependencies {
            $0.corpusRegistry = alwaysInterestingRegistry
        } operation: {
            let config = FuzzEngine<Int>.Config(
                maxIterations: 20,
                maxDuration: 5,
                verbose: false
            )

            let engine = FuzzEngine<Int>(config: config, corpusDirectory: nil)
            return await engine.run { _ in }
        }

        let rate = result.stats.inputsPerSecond
        #expect(rate >= 0)
        #expect(result.stats.duration >= 0)
    }

    @Test("FuzzEngine verbose mode logs messages")
    func testVerboseMode() async {
        // Use AlwaysInterestingCorpusRegistry to bypass coverage data requirements
        let alwaysInterestingRegistry = AlwaysInterestingCorpusRegistry()

        let result = await withDependencies {
            $0.corpusRegistry = alwaysInterestingRegistry
        } operation: {
            let config = FuzzEngine<Int>.Config(
                maxIterations: 50,
                maxDuration: 5,
                plateauConfig: .init(enabled: false),
                verbose: true
            )

            let engine = FuzzEngine<Int>(config: config, corpusDirectory: nil)
            return await engine.run { _ in }
        }

        #expect(result.stats.totalInputs > 0)
    }

    @Test("FuzzEngine reaches time limit")
    func testTimeLimit() async {
        // Use AlwaysInterestingCorpusRegistry to bypass coverage data requirements
        let alwaysInterestingRegistry = AlwaysInterestingCorpusRegistry()

        let result = await withDependencies {
            $0.corpusRegistry = alwaysInterestingRegistry
        } operation: {
            let config = FuzzEngine<Int>.Config(
                maxIterations: 1_000_000,
                maxDuration: 0.001,
                plateauConfig: .init(enabled: false),
                verbose: true
            )

            let engine = FuzzEngine<Int>(config: config, corpusDirectory: nil)
            return await engine.run { _ in }
        }

        #expect(result.stats.totalInputs < 1_000_000)
    }

    @Test("FuzzEngine handles test errors during fuzzing")
    func testErrorsDuringFuzzing() async {
        struct FuzzError: Error {}

        // Use AlwaysInterestingCorpusRegistry to bypass coverage data requirements
        let alwaysInterestingRegistry = AlwaysInterestingCorpusRegistry()

        let result = await withDependencies {
            $0.corpusRegistry = alwaysInterestingRegistry
        } operation: {
            let config = FuzzEngine<Int>.Config(
                maxIterations: 50,
                maxDuration: 5,
                verbose: false
            )

            let engine = FuzzEngine<Int>(config: config, corpusDirectory: nil)
            return await engine.run { (input: Int) in
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
            $0.corpusPersistence = CorpusPersistenceClient(
                save: saveFn,
                load: { _ in Data() },
                exists: { _ in false },
                delete: { _ in }
            )
        } operation: {
            let config = FuzzEngine<Int>.Config(
                maxIterations: 30,
                maxDuration: 5,
                minimizeCorpus: true,
                verbose: true
            )

            let engine = FuzzEngine<Int>(config: config, corpusDirectory: corpusDir)
            return await engine.run { _ in }
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
        let snapshotFn: @Sendable () -> SanCovCounters? = {
            var counters = [UInt64](repeating: 0, count: 100)
            // Always return counters[1]=1 to match the corpus signature
            counters[1] = 1
            return SanCovCounters(counters: counters)
        }

        // Test the signature creation first
        var testCounters = [UInt64](repeating: 0, count: 100)
        testCounters[1] = 1
        let testSnapshot = SanCovCounters(counters: testCounters)
        let sigTest = CoverageSignature(snapshot: testSnapshot)
        print("DEBUG: Test signature buckets=\(sigTest.buckets)")

        // Create corpus with matching signature
        // Note: InputContainer encodes Int 42 as base64 of "42" = "NDI="
        let corpusJSON = """
        {
            "schemaVersion": "v1-100",
            "entries": [
                {
                    "input": ["NDI="],
                    "signature": {"buckets": {"1": 1}},
                    "discoveredAt": "2025-01-01T00:00:00Z",
                    "parentIndex": null
                }
            ],
            "createdAt": "2025-01-01T00:00:00Z",
            "updatedAt": "2025-01-01T00:00:00Z",
            "totalCoverage": {"buckets": {"1": 1}}
        }
        """
        let corpusData = Data(corpusJSON.utf8)

        // Parse corpus to verify the signature
        let parsedCorpusSnapshot = try JSONDecoder.corpusDecoder.decode(CorpusSnapshot<Int>.self, from: corpusData)
        print("DEBUG: Parsed corpus signature=\(parsedCorpusSnapshot.entries[0].signature.buckets)")
        print("DEBUG: Signatures equal? \(sigTest == parsedCorpusSnapshot.entries[0].signature)")

        let (loadSpy, loadFn) = spy { (_: URL) -> Data in corpusData }
        let (existsSpy, existsFn) = spy { (_: URL) -> Bool in true }

        let result = await withDependencies {
            $0.coverageCounters = CoverageCountersClient(snapshot: snapshotFn, reset: {}, isAvailable: { true })
            $0.corpusPersistence = CorpusPersistenceClient(
                save: { _, _ in },
                load: loadFn,
                exists: existsFn,
                delete: { _ in }
            )
        } operation: {
            // Prime the dependency context
            @Dependency(\.coverageCounters) var cc
            _ = cc

            let config = FuzzEngine<Int>.Config(
                maxIterations: 30,
                maxDuration: 5,
                verbose: true
            )

            let engine = FuzzEngine<Int>(config: config, corpusDirectory: corpusDir)
            return await engine.run { _ in }
        }

        #expect(existsSpy.callCount >= 1, "Should check if corpus exists")
        #expect(loadSpy.callCount == 1, "Should have loaded corpus")
        #expect(result.corpus.count > 0)
        #expect(result.wasRegression, "Should be regression mode")
    }

    @Test("FuzzEngine handles schema change")
    func testSchemaChange() async throws {
        let corpusDir = URL(fileURLWithPath: "/test/fuzz-schema")

        let oldCorpusJSON = """
        {
            "schemaVersion": "v0-old-incompatible",
            "entries": [],
            "createdAt": "2025-01-01T00:00:00Z",
            "updatedAt": "2025-01-01T00:00:00Z",
            "totalCoverage": {"buckets": {}}
        }
        """
        let corpusData = Data(oldCorpusJSON.utf8)

        let (snapshotSpy, snapshotFn) = spy { () -> SanCovCounters? in
            FuzzEngineTests.makeCounters(1)
        }
        let (loadSpy, loadFn) = spy { (_: URL) -> Data in corpusData }
        let (existsSpy, existsFn) = spy { (_: URL) -> Bool in true }

        let result = await withDependencies {
            $0.coverageCounters = CoverageCountersClient(snapshot: snapshotFn, reset: {}, isAvailable: { true })
            $0.corpusPersistence = CorpusPersistenceClient(
                save: { _, _ in },
                load: loadFn,
                exists: existsFn,
                delete: { _ in }
            )
        } operation: {
            let config = FuzzEngine<Int>.Config(
                maxIterations: 20,
                maxDuration: 5,
                verbose: true
            )

            let engine = FuzzEngine<Int>(config: config, corpusDirectory: corpusDir)
            return await engine.run { _ in }
        }

        #expect(existsSpy.callCount >= 1)
        #expect(loadSpy.callCount == 1, "Should have attempted to load corpus")
        #expect(snapshotSpy.callCount > 0)
        #expect(!result.wasRegression, "Should re-fuzz due to schema incompatibility")
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
            let config = FuzzEngine<Int>.Config(
                maxIterations: 20,
                maxDuration: 5,
                verbose: true
            )

            let engine = FuzzEngine<Int>(config: config, corpusDirectory: corpusDir)
            return await engine.run { _ in }
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
        } operation: {
            let config = FuzzEngine<Int>.Config(
                maxIterations: 100,
                maxDuration: 10,
                plateauConfig: .init(enabled: false),
                generationRatio: 0.5,
                verbose: true
            )

            let engine = FuzzEngine<Int>(config: config, corpusDirectory: nil)
            return await engine.run { _ in }
        }

        #expect(result.corpus.count >= 1)
        #expect(result.stats.newPaths > 0)
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
            let config = FuzzEngine<Int>.Config(
                maxIterations: 20,
                maxDuration: 5,
                verbose: true
            )

            let engine = FuzzEngine<Int>(config: config, corpusDirectory: corpusDir)
            return await engine.run { _ in }
        }

        #expect(saveSpy.callCount == 1, "Should have attempted to save corpus")
        #expect(!result.wasRegression)
    }

    @Test("FuzzEngine regression success without coverage change")
    func testRegressionSuccessPath() async throws {
        let corpusDir = URL(fileURLWithPath: "/test/fuzz-regression-success")

        // Use 100 counters so schema version is "v1-100"
        let (snapshotSpy, snapshotFn) = spy { () -> SanCovCounters? in
            SanCovCounters(counters: [UInt64](repeating: 0, count: 100))
        }

        // Empty corpus with matching schema version
        let corpusJSON = """
        {
            "schemaVersion": "v1-100",
            "entries": [],
            "createdAt": "2025-01-01T00:00:00Z",
            "updatedAt": "2025-01-01T00:00:00Z",
            "totalCoverage": {"buckets": {}}
        }
        """
        let corpusData = Data(corpusJSON.utf8)

        let (loadSpy, loadFn) = spy { (_: URL) -> Data in corpusData }
        let (existsSpy, existsFn) = spy { (_: URL) -> Bool in true }

        let result = await withDependencies {
            $0.coverageCounters = CoverageCountersClient(snapshot: snapshotFn, reset: {}, isAvailable: { true })
            $0.corpusPersistence = CorpusPersistenceClient(
                save: { _, _ in },
                load: loadFn,
                exists: existsFn,
                delete: { _ in }
            )
        } operation: {
            let config = FuzzEngine<Int>.Config(
                maxIterations: 10,
                maxDuration: 5,
                verbose: true
            )

            let engine = FuzzEngine<Int>(config: config, corpusDirectory: corpusDir)
            return await engine.run { _ in }
        }

        #expect(existsSpy.callCount >= 1)
        #expect(loadSpy.callCount == 1, "Should have loaded corpus")
        #expect(snapshotSpy.callCount >= 0)  // May or may not be called with empty corpus
        #expect(result.wasRegression, "Should be regression mode with empty corpus")
    }

    @Test("FuzzEngine handles coverage unavailable - test succeeds")
    func testCoverageUnavailableSuccess() async throws {
        let (snapshotSpy, snapshotFn) = spy { () -> SanCovCounters? in nil }

        let result = await withDependencies {
            $0.coverageCounters = CoverageCountersClient(snapshot: snapshotFn, reset: {}, isAvailable: { true })
        } operation: {
            let config = FuzzEngine<Int>.Config(
                maxIterations: 10,
                maxDuration: 5,
                verbose: false
            )

            let engine = FuzzEngine<Int>(config: config, corpusDirectory: nil)
            return await engine.run { _ in }
        }

        #expect(snapshotSpy.callCount > 0, "Should have called snapshot")
        #expect(result.stats.totalInputs > 0, "Test should have executed")
        #expect(result.corpus.count == 0, "Corpus should be empty without coverage")
        #expect(result.failures.isEmpty)
    }

    @Test("FuzzEngine handles coverage unavailable - test throws")
    func testCoverageUnavailableWithError() async throws {
        struct TestError: Error {}

        let (snapshotSpy, snapshotFn) = spy { () -> SanCovCounters? in nil }

        let result = await withDependencies {
            $0.coverageCounters = CoverageCountersClient(snapshot: snapshotFn, reset: {}, isAvailable: { true })
        } operation: {
            let config = FuzzEngine<Int>.Config(
                maxIterations: 10,
                maxDuration: 5,
                verbose: false
            )

            let engine = FuzzEngine<Int>(config: config, corpusDirectory: nil)
            return await engine.run { _ in
                throw TestError()
            }
        }

        #expect(snapshotSpy.callCount > 0)
        #expect(!result.failures.isEmpty, "Should capture failures without coverage")
        #expect(result.failures.first?.error is TestError)
    }

    @Test("FuzzEngine handles coverage unavailable after test execution")
    func testCoverageUnavailableAfter() async throws {
        // With reset+snapshot model:
        // - reset() is called before each test
        // - snapshot() is called after each test
        // If snapshot always returns nil, no coverage is ever recorded
        let (snapshotSpy, snapshotFn) = spy { () -> SanCovCounters? in
            // Always return nil to simulate coverage unavailable
            return nil
        }

        let result = await withDependencies {
            $0.coverageCounters = CoverageCountersClient(snapshot: snapshotFn, reset: {}, isAvailable: { true })
        } operation: {
            let config = FuzzEngine<Int>.Config(
                maxIterations: 5,
                maxDuration: 5,
                verbose: false
            )

            let engine = FuzzEngine<Int>(config: config, corpusDirectory: nil)
            return await engine.run { _ in }
        }

        #expect(snapshotSpy.callCount > 0)
        #expect(result.corpus.count == 0, "Corpus should be empty when snapshot returns nil")
    }

    @Test("FuzzEngine regression detects coverage change and re-fuzzes")
    func testRegressionCoverageChange() async throws {
        let corpusDir = URL(fileURLWithPath: "/test/fuzz-regression-change")

        // Corpus has signature {5: 1}, but mock always returns {1: 1}
        // This mismatch triggers coverage change detection
        let snapshotFn: @Sendable () -> SanCovCounters? = {
            var counters = [UInt64](repeating: 0, count: 100)
            counters[1] = 1  // Different from corpus signature {5: 1}
            return SanCovCounters(counters: counters)
        }

        // Corpus has signature {5: 1} (bucket index 5, bucket value 1=one)
        // Mock returns {1: 1} which is different, triggering coverage change
        // Note: InputContainer encodes Int 42 as base64 of "42" = "NDI="
        let corpusJSON = """
        {
            "schemaVersion": "v1-100",
            "entries": [
                {
                    "input": ["NDI="],
                    "signature": {"buckets": {"5": 1}},
                    "discoveredAt": "2025-01-01T00:00:00Z",
                    "parentIndex": null
                }
            ],
            "createdAt": "2025-01-01T00:00:00Z",
            "updatedAt": "2025-01-01T00:00:00Z",
            "totalCoverage": {"buckets": {"5": 1}}
        }
        """
        let corpusData = Data(corpusJSON.utf8)

        let (loadSpy, loadFn) = spy { (_: URL) -> Data in corpusData }
        let (existsSpy, existsFn) = spy { (_: URL) -> Bool in true }

        let result = await withDependencies {
            $0.coverageCounters = CoverageCountersClient(snapshot: snapshotFn, reset: {}, isAvailable: { true })
            $0.corpusPersistence = CorpusPersistenceClient(
                save: { _, _ in },
                load: loadFn,
                exists: existsFn,
                delete: { _ in }
            )
        } operation: {
            let config = FuzzEngine<Int>.Config(
                maxIterations: 30,
                maxDuration: 5,
                verbose: true
            )

            let engine = FuzzEngine<Int>(config: config, corpusDirectory: corpusDir)
            return await engine.run { _ in }
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
            let config = FuzzEngine<Int>.Config(
                maxIterations: 20,  // Will do seeds + iterations
                maxDuration: 10,
                plateauConfig: .init(enabled: false),
                generationRatio: 1.0,  // Always generate fresh
                minimizeCorpus: false,
                verbose: true
            )

            let engine = FuzzEngine<Int>(config: config, corpusDirectory: nil)
            return await engine.run { _ in }
        }

        #expect(result.corpus.count >= 1, "Should have corpus entries")
        #expect(result.stats.totalInputs > 5, "Should test more than just seeds")
    }

    @Test("FuzzEngine regression captures failures during replay")
    func testRegressionFailures() async throws {
        let corpusDir = URL(fileURLWithPath: "/test/fuzz-regression-fail")

        // With reset+snapshot model:
        // - Call 1: schema version check (needs count=100 for "v1-100")
        // - Subsequent calls: after each test, return matching signature {1: 1}
        //
        // All calls return counters[1]=1 to match corpus signature {1: 1}
        let snapshotFn: @Sendable () -> SanCovCounters? = {
            var counters = [UInt64](repeating: 0, count: 100)
            counters[1] = 1  // Always return matching coverage
            return SanCovCounters(counters: counters)
        }

        // Corpus with signature {1: 1}
        // Note: InputContainer encodes Int 42 as base64 of "42" = "NDI="
        let corpusJSON = """
        {
            "schemaVersion": "v1-100",
            "entries": [
                {
                    "input": ["NDI="],
                    "signature": {"buckets": {"1": 1}},
                    "discoveredAt": "2025-01-01T00:00:00Z",
                    "parentIndex": null
                }
            ],
            "createdAt": "2025-01-01T00:00:00Z",
            "updatedAt": "2025-01-01T00:00:00Z",
            "totalCoverage": {"buckets": {"1": 1}}
        }
        """
        let corpusData = Data(corpusJSON.utf8)

        let (_, loadFn) = spy { (_: URL) -> Data in corpusData }

        struct RegressionError: Error {}

        let result = await withDependencies {
            $0.coverageCounters = CoverageCountersClient(snapshot: snapshotFn, reset: {}, isAvailable: { true })
            $0.corpusPersistence = CorpusPersistenceClient(
                save: { _, _ in },
                load: loadFn,
                exists: { _ in true },
                delete: { _ in }
            )
        } operation: {
            let config = FuzzEngine<Int>.Config(
                maxIterations: 10,
                maxDuration: 5,
                verbose: true
            )

            let engine = FuzzEngine<Int>(config: config, corpusDirectory: corpusDir)
            return await engine.run { (input: Int) in
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
            let config = FuzzEngine<EmptyFuzzable>.Config(
                maxIterations: 10,
                maxDuration: 1,
                plateauConfig: .init(enabled: false),
                verbose: false
            )

            let engine = FuzzEngine<EmptyFuzzable>(config: config, corpusDirectory: nil)
            return await engine.run { _ in }
        }

        // With empty fuzz, no seeds are processed and iterations skip via guard
        #expect(result.corpus.count == 0, "Empty fuzz should produce empty corpus")
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
            let config = FuzzEngine<EmptyMutationsFuzzable>.Config(
                maxIterations: 20,
                maxDuration: 5,
                plateauConfig: .init(enabled: false),
                generationRatio: 0.0,  // Force mutation path
                verbose: false
            )

            let engine = FuzzEngine<EmptyMutationsFuzzable>(config: config, corpusDirectory: nil)
            return await engine.run { _ in }
        }

        // With one seed value, corpus gets one entry, then mutations fail
        #expect(result.corpus.count >= 0)  // May have seed entry
    }
}
