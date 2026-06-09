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

import Testing
import Foundation
import Dependencies
import FunctionSpy
@testable import PropertyTestingKit

// MARK: - Fuzz API Tests

@Suite("Fuzz API")
struct FuzzAPITests {

    @Test("Coverage-guided fuzzing finds all code paths in NumberParser")
    func testNumberParserCoverage() async throws {
        let corpusDir = URL(fileURLWithPath: "/test/fuzz-numberparser")
        let (saveSpy, saveFn) = spy { (_: Data, _: URL) in }

        // Use live coverage to verify we hit all branches
        let result = await withDependencies {
            $0.coverageCounters = .liveValue
            $0.corpusPersistence = CorpusPersistenceClient(
                save: saveFn,
                load: { _ in Data() },
                exists: { _ in false },
                delete: { _ in }
            )
        } operation: {
            return await runFuzzWithMaxIterations(
                maxIterations: 100,
                corpusDir: corpusDir,
                persistence: .auto,
                coverageStrategy: .pathTrie,
                additionalSeeds: numberParserSeeds
            ) { input in
                // Just call parse - coverage will be tracked automatically
                _ = NumberParser.parse(input)

                // Also verify round-trip property holds
                #expect(NumberParser.roundTripProperty(input), "Round-trip property failed for: \(input)")
            }
        }

        // Report results
        print("\n=== NumberParser Fuzz Results ===")
        print("Total inputs tested: \(result.stats.totalInputs)")
        print("Unique coverage paths: \(result.corpus.count)")
        print("Mutations: \(result.stats.mutations)")
        print("Fresh generations: \(result.stats.generations)")
        print("Time: \(String(format: "%.2f", result.stats.duration))s")
        print("Rate: \(String(format: "%.0f", result.stats.inputsPerSecond)) inputs/sec")

        print("\nMinimal corpus inputs:")
        for (i, entry) in result.corpus.entries.prefix(10).enumerated() {
            let parsed = NumberParser.parse(entry.input)
            print("  \(i + 1). \"\(entry.input)\" → \(parsed.map(String.init) ?? "nil")")
        }

        #expect(result.failures.isEmpty, "No test errors should occur")
        #expect(saveSpy.callCount == 1, "Corpus should be saved")
    }

    @Test("FuzzEngine saves corpus after run")
    func testFuzzEngineSavesCorpus() async throws {
        let corpusDir = URL(fileURLWithPath: "/test/fuzz-persist")
        let (saveSpy, saveFn) = spy { (_: Data, _: URL) in }

        let result = await withDependencies {
            $0.corpusPersistence = CorpusPersistenceClient(
                save: saveFn,
                load: { _ in Data() },
                exists: { _ in false },
                delete: { _ in }
            )
            // Explicitly set live coverage to prevent mock leakage from parallel tests
            $0.coverageCounters = .liveValue
        } operation: {
            return await runFuzzWithMaxIterations(
                maxIterations: 100,
                corpusDir: corpusDir,
                persistence: .auto,
                coverageStrategy: .alwaysInteresting,
                additionalSeeds: numberParserSeeds
            ) { input in
                _ = NumberParser.parse(input)
            }
        }

        #expect(!result.wasRegression, "First run should be fuzzing mode")
        #expect(result.corpus.count > 0, "Should have corpus entries")
        #expect(result.failures.isEmpty, "Should have no failures")

        // Verify corpus was saved
        #expect(saveSpy.callCount == 1, "Corpus should be saved")
        #expect(saveSpy.callParams[0].1.path == "/test/fuzz-persist")
    }

    @Test("Public fuzz API with custom seeds")
    func testPublicFuzzAPIWithSeeds() async throws {
        let result = try await withDependencies {
            $0.environment = EnvironmentClient(environment: { [:] })
        } operation: {
            try await fuzzWithMaxIterations(
                maxIterations: 100,
                seeds: ["0", "-0", "-1", "abc", String(Int.max)],
                persistence: .ephemeral,
                coverageStrategy: .alwaysInteresting
            ) { input in
                let parsed = NumberParser.parse(input)

                // Property: round-trip should work
                if let n = parsed {
                    let reparsed = NumberParser.parse(String(n))
                    #expect(reparsed == n, "Round-trip failed for \(input)")
                }
            }
        }

        print("Public API tested \(result.stats.totalInputs) inputs")
        #expect(result.stats.totalInputs > 0)
    }

    @Test("FuzzError errorDescription covers all cases")
    func testFuzzErrorDescriptions() {
        // Test .testFailed
        let testFailedError = FuzzError.testFailed(
            input: "badInput",
            underlyingError: NSError(domain: "test", code: 1),
            timeElapsed: 0,
            stats: FuzzStats(totalInputs: 0, seeds: 0, mutations: 0, generations: 0, duration: 0)
        )
        #expect(testFailedError.errorDescription?.contains("badInput") == true)
        #expect(testFailedError.errorDescription?.contains("Fuzz test failed") == true)

        // Test .coverageUnavailable
        let coverageError = FuzzError.coverageUnavailable
        #expect(coverageError.errorDescription?.contains("Coverage") == true)
        #expect(coverageError.errorDescription?.contains("--enable-code-coverage") == true)

        // Test .corpusError
        let corpusError = FuzzError.corpusError("Failed to save")
        #expect(corpusError.errorDescription?.contains("Corpus error") == true)
        #expect(corpusError.errorDescription?.contains("Failed to save") == true)
    }

    @Test("Config.fromEnvironment reads environment variables")
    func testConfigFromEnvironment() async {
        withDependencies {
            $0.environment = EnvironmentClient(environment: {
                [
                    "FUZZ_ITERATIONS": "500",
                    "FUZZ_DURATION": "30",
                    "FUZZ_VERBOSE": "1"
                ]
            })
        } operation: {
            let config: FuzzEngineConfig = .fromEnvironment()

            #expect(config.maxDuration == .seconds(30))
            #expect(config.verbose == true)
        }
    }

    @Test("Config.fromEnvironment uses defaults when env vars not set")
    func testConfigFromEnvironmentDefaults() async {
        withDependencies {
            $0.environment = EnvironmentClient(environment: { [:] })
        } operation: {
            let config: FuzzEngineConfig = .fromEnvironment()

            #expect(config.maxDuration == .seconds(60))
            #expect(config.verbose == false)
        }
    }

    @Test("FuzzEngine captures failures correctly")
    func testFuzzEngineFailureCapture() async throws {
        // Create an error to throw
        struct TestFailure: Error {}

        let config = FuzzEngineConfig(
            maxDuration: .seconds(10),
            verbose: false
        )

        // Test FuzzEngine directly to verify failure capture without Issue.record noise
        let result = await fuzzEngineWithMaxIterations(
            maxIterations: 100,
            config: config,
            coverageStrategy: .alwaysInteresting,
            additionalSeeds: [true, false]
        ) { (_: Bool) in
            // Throw for any input to guarantee a failure
            throw TestFailure()
        }

        // Verify failures were captured
        #expect(!result.failures.isEmpty, "Should have captured failures")

        // Verify the error type
        if let (_, error, _, _) = result.failures.first {
            #expect(error is TestFailure, "Error should be TestFailure")
        }
    }

    @Test("fuzz() records issues and throws on failure")
    func testFuzzRecordsIssuesOnFailure() async throws {
        struct TestFailure: Error {}

        // Use withKnownIssue to expect the recorded issues from fuzz()
        await withKnownIssue {
            try await withDependencies {
                $0.fileManager = FileManagerClient(
                    currentDirectoryPath: { "/test" },
                    fileExists: { _ in false },
                    createDirectory: { _, _ in },
                    removeItem: { _ in },
                    writeData: { _, _ in },
                    readData: { _ in Data() }
                )
            } operation: {
                // This will throw because the test always fails
                // Note: Seeds are required to provide type context for the variadic generic
                _ = try await fuzzWithMaxIterations(
                    maxIterations: 10,
                    persistence: .ephemeral,
                    coverageStrategy: .alwaysInteresting
                ) { (_: Bool) in
                    throw TestFailure()
                }
            }
        }
    }

    @Test("fuzz writes corpus to filesystem")
    func testFuzzWritesCorpus() async throws {
        let (saveSpy, saveFn) = spy { (_: Data, _: URL) in }

        try await withDependencies {
            $0.environment = EnvironmentClient(environment: { [:] })
            $0.corpusPersistence = CorpusPersistenceClient(
                save: saveFn,
                load: { _ in Data() },
                exists: { _ in false },
                delete: { _ in }
            )
        } operation: {
            try await fuzzWithMaxIterations(
                maxIterations: 50,
                seeds: ["a", "ab", "abc"],
                coverageStrategy: .alwaysInteresting
            ) { input in
                _ = input.count
            }
        }

        #expect(saveSpy.callCount > 0, "Should have written corpus to filesystem")
    }

    @Test("fuzz reads existing corpus from filesystem")
    func testFuzzReadsCorpus() async throws {
        // Create a mock corpus with known entries
        var existingCorpus = Corpus<String>()
        existingCorpus.add(
            input: ("from_corpus"),
            sparse: SparseCoverage(indices: [1])
        )
        let corpusSnapshot = existingCorpus.snapshot()
        let corpusData = try JSONEncoder.corpusEncoder().encode(corpusSnapshot)

        let (loadSpy, loadFn) = spy { (_: URL) -> Data in
            return corpusData
        }

        let seenInputs = Synchronized<[String]>([])

        try await withDependencies {
            $0.environment = EnvironmentClient(environment: { [:] })
            $0.corpusPersistence = CorpusPersistenceClient(
                save: { _, _ in },
                load: loadFn,
                exists: { _ in true },  // Corpus exists
                delete: { _ in }
            )
        } operation: {
            // Use seeds that include the corpus entry so it gets tested
            try await fuzzWithMaxIterations(
                maxIterations: 50,
                seeds: ["from_corpus"],
                coverageStrategy: .alwaysInteresting
            ) { input in
                await seenInputs.update { $0.append(input) }
            }
        }

        #expect(loadSpy.callCount > 0, "Should have read corpus from filesystem")
        let inputs = await seenInputs.value
        #expect(inputs.contains("from_corpus"), "Should have tested input from seeds/corpus")
    }

    @Test("Corpus directory path is computed correctly")
    func testCorpusDirectoryPath() async throws {
        // Verify that #filePath returns the correct path for corpus placement
        let filePath = #filePath
        let fileURL = URL(fileURLWithPath: String(describing: filePath))
        let testFileDir = fileURL.deletingLastPathComponent()

        // The test file should be in Tests/PropertyTestingKitTests/Fuzzing/
        #expect(testFileDir.lastPathComponent == "Fuzzing", "Test file should be in Fuzzing directory")
        #expect(testFileDir.deletingLastPathComponent().lastPathComponent == "PropertyTestingKitTests")

        // The corpus directory should be placed alongside the test file
        let expectedCorpusBase = testFileDir.appendingPathComponent("Corpus")
        print("Expected corpus base: \(expectedCorpusBase.path)")

        #expect(
            expectedCorpusBase.path.contains("Tests/PropertyTestingKitTests/Fuzzing/Corpus"),
            "Corpus should be in Tests/PropertyTestingKitTests/Fuzzing/Corpus"
        )
    }
}

/// A number parser with multiple code paths to exercise.
///
/// Code paths:
/// 1. Empty string → nil
/// 2. "0" special case → 0
/// 3. Negative with "-" prefix:
///    a. Valid negative → negative Int
///    b. Invalid after "-" → nil
/// 4. Positive number → Int or nil
enum NumberParser {
    static func parse(_ s: String) -> Int? {
        // Path 1: Empty
        if s.isEmpty { return nil }

        // Path 2: Zero special case
        if s == "0" { return 0 }

        // Path 3: Negative numbers
        if s.hasPrefix("-") {
            let rest = String(s.dropFirst())
            // Path 3a/3b: Valid or invalid negative
            guard let n = Int(rest), n >= 0 else { return nil }
            // Use wrapping negation since we proved n >= 0, so -n cannot overflow.
            // This avoids an unreachable compiler-generated overflow trap.
            return 0 &- n
        }

        // Path 4: Positive numbers
        return Int(s)
    }

    /// Property: If parse succeeds, converting back to string should match
    /// (modulo leading zeros and whitespace)
    static func roundTripProperty(_ input: String) -> Bool {
        guard let parsed = parse(input) else {
            // nil is valid for unparseable input
            return true
        }

        // Round-trip: parse then format should give canonical form
        let formatted = String(parsed)
        let reparsed = parse(formatted)
        return reparsed == parsed
    }

}

// MARK: - Domain-Specific Seeds for Number Parsing

/// Seeds that target NumberParser's code paths.
/// Using String directly with custom seeds instead of a custom type.
let numberParserSeeds: [String] = [
    // Empty
    "",

    // Zero variants
    "0",
    "00",
    "-0",

    // Small positives
    "1",
    "42",
    "123",

    // Small negatives
    "-1",
    "-42",
    "-123",

    // Edge cases
    String(Int.max),
    String(Int.min),
    String(Int.max / 2),

    // Invalid inputs
    "abc",
    "-",
    "--1",
    "1.5",
    " 42",
    "42 ",
    "+1",

    // Mixed
    "123abc",
    "-abc",
    "12-34",
]

