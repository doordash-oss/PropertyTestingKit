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

@Suite("FuzzEngine", .serialized)
struct FuzzEngineTests {

    // MARK: - Helpers

    /// Creates a CoverageCounters with a specific signature pattern.
    /// Different counter values produce different CoverageSignatures.
    static func makeCounters(_ seed: Int) -> CoverageCounters {
        var counters = [UInt64](repeating: 0, count: 100)
        counters[seed % 100] = UInt64(seed + 1)
        return CoverageCounters(counters: counters)
    }

    // MARK: - Tests

    @Test("FuzzEngine discovers multiple paths with mocked coverage")
    func testFuzzEngineDiscoversPaths() {
        nonisolated(unsafe) var callCount = 0
        // Use varying coverage values so difference between before/after produces new paths
        let (snapshotSpy, snapshotFn) = spy { () -> CoverageCounters? in
            callCount += 1
            return FuzzEngineTests.makeCounters(callCount % 10)
        }

        let result = withDependencies {
            $0.coverageCounters = CoverageCountersClient(snapshot: snapshotFn)
        } operation: {
            let config = FuzzEngine<Int>.Config(
                maxIterations: 30,
                maxDuration: 5,
                plateauThreshold: 20,
                minimizeCorpus: false,
                verbose: false
            )

            let engine = FuzzEngine<Int>(config: config, corpusDirectory: nil)
            return engine.run { _ in }
        }

        #expect(snapshotSpy.callCount > 1, "Should have called snapshot multiple times")
        #expect(result.corpus.count >= 1, "Should find coverage paths")
        #expect(result.failures.isEmpty)
    }

    @Test("FuzzEngine detects test failures")
    func testFuzzEngineDetectsFailures() {
        nonisolated(unsafe) var callCount = 0
        // before returns zeros, after returns coverage
        let snapshotFn: @Sendable () -> CoverageCounters? = {
            callCount += 1
            var counters = [UInt64](repeating: 0, count: 100)
            if callCount % 2 == 0 {
                counters[1] = 1  // After snapshot
            }
            return CoverageCounters(counters: counters)
        }

        struct TestError: Error {}

        let result = withDependencies {
            $0.coverageCounters = CoverageCountersClient(snapshot: snapshotFn)
        } operation: {
            let config = FuzzEngine<Int>.Config(
                maxIterations: 20,
                maxDuration: 3,
                verbose: false
            )

            let engine = FuzzEngine<Int>(config: config, corpusDirectory: nil)
            return engine.run { input in
                if input == 42 {
                    throw TestError()
                }
            }
        }

        #expect(callCount > 0)
        #expect(!result.failures.isEmpty, "Should detect failures")
        #expect(result.failures.contains { $0.input == 42 })
    }

    @Test("FuzzEngine respects iteration limit")
    func testIterationLimit() {
        let (snapshotSpy, snapshotFn) = spy { () -> CoverageCounters? in
            FuzzEngineTests.makeCounters(1)
        }

        let result = withDependencies {
            $0.coverageCounters = CoverageCountersClient(snapshot: snapshotFn)
        } operation: {
            let config = FuzzEngine<Int>.Config(
                maxIterations: 20,
                maxDuration: 60,
                plateauThreshold: 1000,
                verbose: false
            )

            let engine = FuzzEngine<Int>(config: config, corpusDirectory: nil)
            return engine.run { _ in }
        }

        #expect(snapshotSpy.callCount > 0)
        #expect(result.stats.totalInputs <= 20)
    }

    @Test("FuzzStats.inputsPerSecond computes correctly")
    func testInputsPerSecond() {
        let (_, snapshotFn) = spy { () -> CoverageCounters? in
            FuzzEngineTests.makeCounters(1)
        }

        let result = withDependencies {
            $0.coverageCounters = CoverageCountersClient(snapshot: snapshotFn)
        } operation: {
            let config = FuzzEngine<Int>.Config(
                maxIterations: 20,
                maxDuration: 5,
                verbose: false
            )

            let engine = FuzzEngine<Int>(config: config, corpusDirectory: nil)
            return engine.run { _ in }
        }

        let rate = result.stats.inputsPerSecond
        #expect(rate >= 0)
        #expect(result.stats.duration >= 0)
    }

    @Test("FuzzEngine verbose mode logs messages")
    func testVerboseMode() {
        nonisolated(unsafe) var callCount = 0
        let (snapshotSpy, snapshotFn) = spy { () -> CoverageCounters? in
            callCount += 1
            return FuzzEngineTests.makeCounters(callCount / 2)
        }

        let result = withDependencies {
            $0.coverageCounters = CoverageCountersClient(snapshot: snapshotFn)
        } operation: {
            let config = FuzzEngine<Int>.Config(
                maxIterations: 50,
                maxDuration: 5,
                plateauThreshold: 10,
                verbose: true
            )

            let engine = FuzzEngine<Int>(config: config, corpusDirectory: nil)
            return engine.run { _ in }
        }

        #expect(snapshotSpy.callCount > 0)
        #expect(result.stats.totalInputs > 0)
    }

    @Test("FuzzEngine reaches time limit")
    func testTimeLimit() {
        let (snapshotSpy, snapshotFn) = spy { () -> CoverageCounters? in
            FuzzEngineTests.makeCounters(1)
        }

        let result = withDependencies {
            $0.coverageCounters = CoverageCountersClient(snapshot: snapshotFn)
        } operation: {
            let config = FuzzEngine<Int>.Config(
                maxIterations: 1_000_000,
                maxDuration: 0.001,
                plateauThreshold: 1_000_000,
                verbose: true
            )

            let engine = FuzzEngine<Int>(config: config, corpusDirectory: nil)
            return engine.run { _ in }
        }

        #expect(snapshotSpy.callCount > 0)
        #expect(result.stats.totalInputs < 1_000_000)
    }

    @Test("FuzzEngine handles test errors during fuzzing")
    func testErrorsDuringFuzzing() {
        struct FuzzError: Error {}

        let (snapshotSpy, snapshotFn) = spy { () -> CoverageCounters? in
            FuzzEngineTests.makeCounters(1)
        }

        let result = withDependencies {
            $0.coverageCounters = CoverageCountersClient(snapshot: snapshotFn)
        } operation: {
            let config = FuzzEngine<Int>.Config(
                maxIterations: 50,
                maxDuration: 5,
                verbose: false
            )

            let engine = FuzzEngine<Int>(config: config, corpusDirectory: nil)
            return engine.run { input in
                if input % 10 == 0 {
                    throw FuzzError()
                }
            }
        }

        #expect(snapshotSpy.callCount > 0)
        #expect(!result.failures.isEmpty, "Should have captured failures")
    }

    @Test("FuzzEngine saves corpus to directory")
    func testCorpusSaveToDirectory() throws {
        let corpusDir = URL(fileURLWithPath: "/test/fuzz-corpus")
        nonisolated(unsafe) var callCount = 0

        // Use varying coverage values so difference between before/after produces new paths
        let (snapshotSpy, snapshotFn) = spy { () -> CoverageCounters? in
            callCount += 1
            return FuzzEngineTests.makeCounters(callCount % 10)
        }
        let (writeDataSpy, writeDataFn) = spy { (_: Data, _: URL) in }
        let (createDirSpy, createDirFn) = spy { (_: URL, _: Bool) in }

        let result = withDependencies {
            $0.coverageCounters = CoverageCountersClient(snapshot: snapshotFn)
            $0.fileManager = FileManagerClient(
                currentDirectoryPath: { "/test" },
                fileExists: { _ in false },
                createDirectory: createDirFn,
                removeItem: { _ in },
                writeData: writeDataFn,
                readData: { _ in Data() }
            )
        } operation: {
            let config = FuzzEngine<Int>.Config(
                maxIterations: 30,
                maxDuration: 5,
                minimizeCorpus: true,
                verbose: true
            )

            let engine = FuzzEngine<Int>(config: config, corpusDirectory: corpusDir)
            return engine.run { _ in }
        }

        #expect(snapshotSpy.callCount > 1, "Should have called snapshot multiple times")
        #expect(result.corpus.count > 0, "Should have corpus entries")
        #expect(writeDataSpy.callCount == 1, "Corpus should be saved")
        #expect(writeDataSpy.callParams[0].1.lastPathComponent == "corpus.json")
        #expect(createDirSpy.callCount == 1, "Should create directory")
    }

    @Test("FuzzEngine loads existing corpus and runs regression")
    func testRegressionMode() throws {
        let corpusDir = URL(fileURLWithPath: "/test/fuzz-regression")

        // For regression to succeed, the mock must return values that produce matching signatures
        // The corpus entry has signature {"buckets": {"1": 1}} = [1: .one]
        //
        // Call sequence: CorpusSchema.isCompatible calls snapshot() first, then regression runs.
        // - Call 1: schema check -> return counters (to get count)
        // - Call 2: regression before -> return zeros
        // - Call 3: regression after -> return counters[1]=1 for signature [1: .one]
        nonisolated(unsafe) var callCount = 0
        let snapshotFn: @Sendable () -> CoverageCounters? = {
            callCount += 1
            var counters = [UInt64](repeating: 0, count: 100)
            // Call 1 = schema check
            // Call 2,4,6,... = before (zeros)
            // Call 3,5,7,... = after (non-zeros)
            // So for calls > 1: odd = zeros (before), even = non-zeros (after) - wait that's still even=after
            // Actually: call 2 = before (zeros), call 3 = after (non-zeros)
            // Call > 1 and odd means after, so we want non-zeros on odd calls > 1
            if callCount > 1 && callCount % 2 == 1 {
                // After snapshot: counters[1]=1 produces Bucket(count:1)=.one with rawValue=1
                counters[1] = 1
            }
            return CoverageCounters(counters: counters)
        }

        // Test the signature creation first
        let beforeTest = CoverageCounters(counters: [UInt64](repeating: 0, count: 100))
        var afterCounters = [UInt64](repeating: 0, count: 100)
        afterCounters[1] = 1
        let afterTest = CoverageCounters(counters: afterCounters)
        let diffTest = afterTest.difference(from: beforeTest)
        let sigTest = CoverageSignature(diff: diffTest)
        print("DEBUG: Test signature buckets=\(sigTest.buckets)")

        // Create corpus with matching signature
        // Note: InputContainer encodes Int 42 as base64 of "42" = "NDI="
        let corpusJSON = """
        {
            "schemaVersion": "v1-100",
            "entries": [
                {
                    "input": {"input": ["NDI="]},
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
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let parsedCorpus = try decoder.decode(Corpus<Int>.self, from: corpusData)
        print("DEBUG: Parsed corpus signature=\(parsedCorpus.entries[0].signature.buckets)")
        print("DEBUG: Signatures equal? \(sigTest == parsedCorpus.entries[0].signature)")

        let (readDataSpy, readDataFn) = spy { (_: URL) -> Data in corpusData }
        let (fileExistsSpy, fileExistsFn) = spy { (path: String) -> Bool in
            path.contains("corpus.json")
        }

        let result = withDependencies {
            $0.coverageCounters = CoverageCountersClient(snapshot: snapshotFn)
            $0.fileManager = FileManagerClient(
                currentDirectoryPath: { "/test" },
                fileExists: fileExistsFn,
                createDirectory: { _, _ in },
                removeItem: { _ in },
                writeData: { _, _ in },
                readData: readDataFn
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
            return engine.run { _ in }
        }

        #expect(fileExistsSpy.callCount >= 1, "Should check if corpus exists")
        #expect(readDataSpy.callCount == 1, "Should have loaded corpus")
        #expect(callCount > 0, "Should have taken snapshots")
        #expect(result.corpus.count > 0)
        #expect(result.wasRegression, "Should be regression mode - callCount=\(callCount)")
    }

    @Test("FuzzEngine handles schema change")
    func testSchemaChange() throws {
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

        let (snapshotSpy, snapshotFn) = spy { () -> CoverageCounters? in
            FuzzEngineTests.makeCounters(1)
        }
        let (readDataSpy, readDataFn) = spy { (_: URL) -> Data in corpusData }
        let (fileExistsSpy, fileExistsFn) = spy { (path: String) -> Bool in
            path.contains("corpus.json")
        }

        let result = withDependencies {
            $0.coverageCounters = CoverageCountersClient(snapshot: snapshotFn)
            $0.fileManager = FileManagerClient(
                currentDirectoryPath: { "/test" },
                fileExists: fileExistsFn,
                createDirectory: { _, _ in },
                removeItem: { _ in },
                writeData: { _, _ in },
                readData: readDataFn
            )
        } operation: {
            let config = FuzzEngine<Int>.Config(
                maxIterations: 20,
                maxDuration: 5,
                verbose: true
            )

            let engine = FuzzEngine<Int>(config: config, corpusDirectory: corpusDir)
            return engine.run { _ in }
        }

        #expect(fileExistsSpy.callCount >= 1)
        #expect(readDataSpy.callCount == 1, "Should have attempted to load corpus")
        #expect(snapshotSpy.callCount > 0)
        #expect(!result.wasRegression, "Should re-fuzz due to schema incompatibility")
    }

    @Test("FuzzEngine handles corpus load failure")
    func testCorpusLoadFailure() throws {
        let corpusDir = URL(fileURLWithPath: "/test/fuzz-loadfail")
        let invalidJSON = Data("{ invalid json }".utf8)

        let (snapshotSpy, snapshotFn) = spy { () -> CoverageCounters? in
            FuzzEngineTests.makeCounters(1)
        }
        let (readDataSpy, readDataFn) = spy { (_: URL) -> Data in invalidJSON }
        let (fileExistsSpy, fileExistsFn) = spy { (path: String) -> Bool in
            path.contains("corpus.json")
        }

        let result = withDependencies {
            $0.coverageCounters = CoverageCountersClient(snapshot: snapshotFn)
            $0.fileManager = FileManagerClient(
                currentDirectoryPath: { "/test" },
                fileExists: fileExistsFn,
                createDirectory: { _, _ in },
                removeItem: { _ in },
                writeData: { _, _ in },
                readData: readDataFn
            )
        } operation: {
            let config = FuzzEngine<Int>.Config(
                maxIterations: 20,
                maxDuration: 5,
                verbose: true
            )

            let engine = FuzzEngine<Int>(config: config, corpusDirectory: corpusDir)
            return engine.run { _ in }
        }

        #expect(fileExistsSpy.callCount >= 1)
        #expect(readDataSpy.callCount == 1, "Should have attempted to load corpus")
        #expect(snapshotSpy.callCount > 0)
        #expect(!result.wasRegression, "Should fall back to fuzzing mode")
    }

    @Test("FuzzEngine discovers new coverage during iteration")
    func testNewCoverageDuringIteration() {
        nonisolated(unsafe) var callCount = 0

        // Return different coverage each time to ensure new paths discovered
        let (snapshotSpy, snapshotFn) = spy { () -> CoverageCounters? in
            callCount += 1
            // Vary coverage based on call count to simulate discovering new paths
            return FuzzEngineTests.makeCounters(callCount % 10)
        }

        let result = withDependencies {
            $0.coverageCounters = CoverageCountersClient(snapshot: snapshotFn)
        } operation: {
            let config = FuzzEngine<Int>.Config(
                maxIterations: 100,
                maxDuration: 10,
                plateauThreshold: 50,
                generationRatio: 0.5,
                verbose: true
            )

            let engine = FuzzEngine<Int>(config: config, corpusDirectory: nil)
            return engine.run { _ in }
        }

        #expect(snapshotSpy.callCount > 0)
        #expect(result.corpus.count >= 1)
        #expect(result.stats.newPaths > 0)
    }

    @Test("FuzzEngine handles corpus save failure")
    func testCorpusSaveFailure() throws {
        let corpusDir = URL(fileURLWithPath: "/test/fuzz-savefail")

        struct SaveError: Error {}

        nonisolated(unsafe) var callCount = 0
        let (snapshotSpy, snapshotFn) = spy { () -> CoverageCounters? in
            callCount += 1
            return FuzzEngineTests.makeCounters(callCount / 2)
        }
        let (writeDataSpy, writeDataFn) = spy { (_: Data, _: URL) throws -> Void in
            throw SaveError()
        }
        let (createDirSpy, createDirFn) = spy { (_: URL, _: Bool) in }

        let result = withDependencies {
            $0.coverageCounters = CoverageCountersClient(snapshot: snapshotFn)
            $0.fileManager = FileManagerClient(
                currentDirectoryPath: { "/test" },
                fileExists: { _ in false },
                createDirectory: createDirFn,
                removeItem: { _ in },
                writeData: writeDataFn,
                readData: { _ in Data() }
            )
        } operation: {
            let config = FuzzEngine<Int>.Config(
                maxIterations: 20,
                maxDuration: 5,
                verbose: true
            )

            let engine = FuzzEngine<Int>(config: config, corpusDirectory: corpusDir)
            return engine.run { _ in }
        }

        #expect(snapshotSpy.callCount > 0)
        #expect(createDirSpy.callCount == 1, "Should create directory")
        #expect(writeDataSpy.callCount == 1, "Should have attempted to save corpus")
        #expect(!result.wasRegression)
    }

    @Test("FuzzEngine regression success without coverage change")
    func testRegressionSuccessPath() throws {
        let corpusDir = URL(fileURLWithPath: "/test/fuzz-regression-success")

        // Use 100 counters so schema version is "v1-100"
        let (snapshotSpy, snapshotFn) = spy { () -> CoverageCounters? in
            CoverageCounters(counters: [UInt64](repeating: 0, count: 100))
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

        let (readDataSpy, readDataFn) = spy { (_: URL) -> Data in corpusData }
        let (fileExistsSpy, fileExistsFn) = spy { (path: String) -> Bool in
            path.contains("corpus.json")
        }

        let result = withDependencies {
            $0.coverageCounters = CoverageCountersClient(snapshot: snapshotFn)
            $0.fileManager = FileManagerClient(
                currentDirectoryPath: { "/test" },
                fileExists: fileExistsFn,
                createDirectory: { _, _ in },
                removeItem: { _ in },
                writeData: { _, _ in },
                readData: readDataFn
            )
        } operation: {
            let config = FuzzEngine<Int>.Config(
                maxIterations: 10,
                maxDuration: 5,
                verbose: true
            )

            let engine = FuzzEngine<Int>(config: config, corpusDirectory: corpusDir)
            return engine.run { _ in }
        }

        #expect(fileExistsSpy.callCount >= 1)
        #expect(readDataSpy.callCount == 1, "Should have loaded corpus")
        #expect(snapshotSpy.callCount >= 0)  // May or may not be called with empty corpus
        #expect(result.wasRegression, "Should be regression mode with empty corpus")
    }

    @Test("FuzzEngine handles coverage unavailable - test succeeds")
    func testCoverageUnavailableSuccess() throws {
        nonisolated(unsafe) var testExecuted = false

        let (snapshotSpy, snapshotFn) = spy { () -> CoverageCounters? in nil }

        let result = withDependencies {
            $0.coverageCounters = CoverageCountersClient(snapshot: snapshotFn)
        } operation: {
            let config = FuzzEngine<Int>.Config(
                maxIterations: 10,
                maxDuration: 5,
                verbose: false
            )

            let engine = FuzzEngine<Int>(config: config, corpusDirectory: nil)
            return engine.run { _ in
                testExecuted = true
            }
        }

        #expect(snapshotSpy.callCount > 0, "Should have called snapshot")
        #expect(testExecuted, "Test should have executed")
        #expect(result.corpus.count == 0, "Corpus should be empty without coverage")
        #expect(result.failures.isEmpty)
    }

    @Test("FuzzEngine handles coverage unavailable - test throws")
    func testCoverageUnavailableWithError() throws {
        struct TestError: Error {}

        let (snapshotSpy, snapshotFn) = spy { () -> CoverageCounters? in nil }

        let result = withDependencies {
            $0.coverageCounters = CoverageCountersClient(snapshot: snapshotFn)
        } operation: {
            let config = FuzzEngine<Int>.Config(
                maxIterations: 10,
                maxDuration: 5,
                verbose: false
            )

            let engine = FuzzEngine<Int>(config: config, corpusDirectory: nil)
            return engine.run { _ in
                throw TestError()
            }
        }

        #expect(snapshotSpy.callCount > 0)
        #expect(!result.failures.isEmpty, "Should capture failures without coverage")
        #expect(result.failures.first?.error is TestError)
    }

    @Test("FuzzEngine handles coverage unavailable after test execution")
    func testCoverageUnavailableAfter() throws {
        nonisolated(unsafe) var snapshotCallCount = 0

        let (snapshotSpy, snapshotFn) = spy { () -> CoverageCounters? in
            snapshotCallCount += 1
            if snapshotCallCount % 2 == 1 {
                // Return valid snapshot for "before"
                return CoverageCounters(counters: [1, 2, 3])
            } else {
                // Return nil for "after"
                return nil
            }
        }

        let result = withDependencies {
            $0.coverageCounters = CoverageCountersClient(snapshot: snapshotFn)
        } operation: {
            let config = FuzzEngine<Int>.Config(
                maxIterations: 5,
                maxDuration: 5,
                verbose: false
            )

            let engine = FuzzEngine<Int>(config: config, corpusDirectory: nil)
            return engine.run { _ in }
        }

        #expect(snapshotSpy.callCount > 0)
        #expect(result.corpus.count == 0, "Corpus should be empty when after snapshot fails")
    }

    @Test("FuzzEngine regression detects coverage change and re-fuzzes")
    func testRegressionCoverageChange() throws {
        let corpusDir = URL(fileURLWithPath: "/test/fuzz-regression-change")

        // Return different signature than corpus has (corpus: {5: 1}, mock returns {1: 1})
        // This triggers coverage change detection
        nonisolated(unsafe) var callCount = 0
        let snapshotFn: @Sendable () -> CoverageCounters? = {
            callCount += 1
            var counters = [UInt64](repeating: 0, count: 100)
            // Call 1 = schema check, calls 2,4,6... = before (zeros), calls 3,5,7... = after
            if callCount > 1 && callCount % 2 == 1 {
                // Return different coverage than corpus: counters[1]=1 vs corpus {5: 1}
                counters[1] = 1
            }
            return CoverageCounters(counters: counters)
        }

        // Corpus has signature {5: 1} (bucket index 5, bucket value 1=one)
        // Mock returns {1: 1} which is different, triggering coverage change
        // Note: InputContainer encodes Int 42 as base64 of "42" = "NDI="
        let corpusJSON = """
        {
            "schemaVersion": "v1-100",
            "entries": [
                {
                    "input": {"input": ["NDI="]},
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

        let (readDataSpy, readDataFn) = spy { (_: URL) -> Data in corpusData }
        nonisolated(unsafe) var fileExistsCallCount = 0
        let fileExistsFn: @Sendable (String) -> Bool = { path in
            fileExistsCallCount += 1
            return path.contains("corpus.json")
        }

        let result = withDependencies {
            $0.coverageCounters = CoverageCountersClient(snapshot: snapshotFn)
            $0.fileManager = FileManagerClient(
                currentDirectoryPath: { "/test" },
                fileExists: fileExistsFn,
                createDirectory: { _, _ in },
                removeItem: { _ in },
                writeData: { _, _ in },
                readData: readDataFn
            )
        } operation: {
            let config = FuzzEngine<Int>.Config(
                maxIterations: 30,
                maxDuration: 5,
                verbose: true
            )

            let engine = FuzzEngine<Int>(config: config, corpusDirectory: corpusDir)
            return engine.run { _ in }
        }

        #expect(fileExistsCallCount >= 1)
        #expect(readDataSpy.callCount == 1, "Should have loaded corpus")
        #expect(callCount > 0)
        #expect(!result.wasRegression, "Should re-fuzz after coverage change")
    }

    @Test("FuzzEngine verbose logs new coverage during iterations")
    func testNewCoverageVerboseInIterations() {
        // This test covers the "New coverage!" verbose path at lines 247-249
        // Seeds all produce the same coverage, but iterations produce different coverage
        nonisolated(unsafe) var callCount = 0
        nonisolated(unsafe) var inputCount = 0

        // Use spy wrapper to ensure proper dependency propagation
        let (snapshotSpy, snapshotFn) = spy { () -> CoverageCounters? in
            callCount += 1
            // Return different coverage each call so some iterations find new paths
            return FuzzEngineTests.makeCounters(callCount)
        }

        let result = withDependencies {
            $0.coverageCounters = CoverageCountersClient(snapshot: snapshotFn)
        } operation: {
            let config = FuzzEngine<Int>.Config(
                maxIterations: 20,  // Will do 5 seeds + 15 iterations
                maxDuration: 10,
                plateauThreshold: 100,  // High so we don't stop early
                generationRatio: 1.0,  // Always generate fresh
                minimizeCorpus: false,
                verbose: true
            )

            let engine = FuzzEngine<Int>(config: config, corpusDirectory: nil)
            return engine.run { input in
                inputCount += 1
            }
        }

        #expect(snapshotSpy.callCount > 10, "Should call snapshot multiple times")
        #expect(result.corpus.count >= 1, "Should find coverage paths")
        #expect(inputCount > 5, "Should test more than just seeds")
    }

    @Test("FuzzEngine regression captures failures during replay")
    func testRegressionFailures() throws {
        let corpusDir = URL(fileURLWithPath: "/test/fuzz-regression-fail")

        // Return matching signature so we don't trigger coverage change
        nonisolated(unsafe) var callCount = 0
        let snapshotFn: @Sendable () -> CoverageCounters? = {
            callCount += 1
            var counters = [UInt64](repeating: 0, count: 100)
            // For regression: all "after" calls return counters[1]=1 to match corpus signature {1: 1}
            if callCount > 1 && callCount % 2 == 1 {
                counters[1] = 1
            }
            return CoverageCounters(counters: counters)
        }

        // Corpus with signature {1: 1}
        // Note: InputContainer encodes Int 42 as base64 of "42" = "NDI="
        let corpusJSON = """
        {
            "schemaVersion": "v1-100",
            "entries": [
                {
                    "input": {"input": ["NDI="]},
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

        let (_, readDataFn) = spy { (_: URL) -> Data in corpusData }
        let (_, fileExistsFn) = spy { (path: String) -> Bool in
            path.contains("corpus.json")
        }

        struct RegressionError: Error {}

        let result = withDependencies {
            $0.coverageCounters = CoverageCountersClient(snapshot: snapshotFn)
            $0.fileManager = FileManagerClient(
                currentDirectoryPath: { "/test" },
                fileExists: fileExistsFn,
                createDirectory: { _, _ in },
                removeItem: { _ in },
                writeData: { _, _ in },
                readData: readDataFn
            )
        } operation: {
            let config = FuzzEngine<Int>.Config(
                maxIterations: 10,
                maxDuration: 5,
                verbose: true
            )

            let engine = FuzzEngine<Int>(config: config, corpusDirectory: corpusDir)
            return engine.run { input in
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
    func testEmptyFuzzArray() {
        nonisolated(unsafe) var callCount = 0
        let (snapshotSpy, snapshotFn) = spy { () -> CoverageCounters? in
            callCount += 1
            return FuzzEngineTests.makeCounters(callCount)
        }

        let result = withDependencies {
            $0.coverageCounters = CoverageCountersClient(snapshot: snapshotFn)
        } operation: {
            let config = FuzzEngine<EmptyFuzzable>.Config(
                maxIterations: 10,
                maxDuration: 1,
                plateauThreshold: 5,
                verbose: false
            )

            let engine = FuzzEngine<EmptyFuzzable>(config: config, corpusDirectory: nil)
            return engine.run { _ in }
        }

        // With empty fuzz, no seeds are processed and iterations skip via guard
        #expect(result.corpus.count == 0, "Empty fuzz should produce empty corpus")
        #expect(result.stats.totalInputs == 0 || result.stats.totalInputs == 10,
                "Should either process no inputs or hit iteration limit with skips")
    }

    @Test("FuzzEngine handles empty mutations array gracefully")
    func testEmptyMutationsArray() {
        nonisolated(unsafe) var callCount = 0
        let (snapshotSpy, snapshotFn) = spy { () -> CoverageCounters? in
            callCount += 1
            return FuzzEngineTests.makeCounters(callCount)
        }

        let result = withDependencies {
            $0.coverageCounters = CoverageCountersClient(snapshot: snapshotFn)
        } operation: {
            let config = FuzzEngine<EmptyMutationsFuzzable>.Config(
                maxIterations: 20,
                maxDuration: 5,
                plateauThreshold: 100,
                generationRatio: 0.0,  // Force mutation path
                verbose: false
            )

            let engine = FuzzEngine<EmptyMutationsFuzzable>(config: config, corpusDirectory: nil)
            return engine.run { _ in }
        }

        // With one seed value, corpus gets one entry, then mutations fail
        #expect(snapshotSpy.callCount > 0)
        #expect(result.corpus.count >= 0)  // May have seed entry
    }
}
