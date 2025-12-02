//
//  FuzzAPITests.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Testing
import Foundation
import Dependencies
import FunctionSpy
@testable import PropertyTestingKit

// MARK: - Number Parser Under Test

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
            return -n  // Returns 0 for "-0"
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

    /// Property: Negation is consistent
    static func negationProperty(_ input: String) -> Bool {
        guard let parsed = parse(input), parsed != Int.min, parsed != 0 else {
            return true  // Skip nil, Int.min (can't negate), and 0 (edge case)
        }

        let negatedString = parsed < 0 ? String(-parsed) : "-\(parsed)"
        guard let negatedParsed = parse(negatedString) else {
            return false  // Should be parseable
        }

        return negatedParsed == -parsed
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

// MARK: - Fuzz API Tests

@Suite("Fuzz API", .serialized)
struct FuzzAPITests {

    @Test("Coverage-guided fuzzing finds all code paths in NumberParser")
    func testNumberParserCoverage() throws {
        let corpusDir = URL(fileURLWithPath: "/test/fuzz-numberparser")
        let (writeDataSpy, writeDataFn) = spy { (_: Data, _: URL) in }

        // Track which code paths we hit
        var sawEmpty = false
        var sawZero = false
        var sawNegativeValid = false
        var sawNegativeInvalid = false
        var sawPositiveValid = false
        var sawPositiveInvalid = false
        var roundTripFailures: [String] = []

        let result = withDependencies {
            $0.fileManager = FileManagerClient(
                currentDirectoryPath: { "/test" },
                fileExists: { _ in false },
                createDirectory: { _, _ in },
                removeItem: { _ in },
                writeData: writeDataFn,
                readData: { _ in Data() }
            )
        } operation: {
            let config = FuzzEngine<String>.Config(
                maxIterations: 100,
                maxDuration: 5,
                plateauThreshold: 30,
                generationRatio: 0.2,
                minimizeCorpus: true,
                verbose: true
            )

            let engine = FuzzEngine<String>(config: config, corpusDirectory: corpusDir)

            // Use String directly with domain-specific seeds
            return engine.run(additionalSeeds: numberParserSeeds) { input in
                let parsed = NumberParser.parse(input)

                // Track paths
                if input.isEmpty {
                    sawEmpty = true
                } else if input == "0" {
                    sawZero = true
                } else if input.hasPrefix("-") {
                    if parsed != nil {
                        sawNegativeValid = true
                    } else {
                        sawNegativeInvalid = true
                    }
                } else {
                    if parsed != nil {
                        sawPositiveValid = true
                    } else {
                        sawPositiveInvalid = true
                    }
                }

                // Verify round-trip property
                if !NumberParser.roundTripProperty(input) {
                    roundTripFailures.append(input)
                }
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

        print("\nCode paths hit:")
        print("  Empty string: \(sawEmpty ? "✓" : "✗")")
        print("  Zero special case: \(sawZero ? "✓" : "✗")")
        print("  Valid negative: \(sawNegativeValid ? "✓" : "✗")")
        print("  Invalid negative: \(sawNegativeInvalid ? "✓" : "✗")")
        print("  Valid positive: \(sawPositiveValid ? "✓" : "✗")")
        print("  Invalid positive: \(sawPositiveInvalid ? "✓" : "✗")")

        print("\nMinimal corpus inputs:")
        for (i, entry) in result.corpus.entries.prefix(10).enumerated() {
            let parsed = NumberParser.parse(entry.input)
            print("  \(i + 1). \"\(entry.input)\" → \(parsed.map(String.init) ?? "nil")")
        }

        // Verify we hit all paths
        #expect(sawEmpty, "Should test empty string")
        #expect(sawZero, "Should test zero")
        #expect(sawNegativeValid, "Should test valid negative")
        #expect(sawNegativeInvalid, "Should test invalid negative")
        #expect(sawPositiveValid, "Should test valid positive")
        #expect(sawPositiveInvalid, "Should test invalid positive")

        #expect(result.failures.isEmpty, "No test errors should occur")
        #expect(roundTripFailures.isEmpty, "Round-trip property should hold for all inputs: \(roundTripFailures)")

        // Verify corpus was saved
        #expect(writeDataSpy.callCount == 1, "Corpus should be saved")
    }

    @Test("Fuzzing verifies negation property")
    func testNegationProperty() throws {
        let corpusDir = URL(fileURLWithPath: "/test/fuzz-negation")

        var negationFailures: [String] = []
        let result = withDependencies {
            $0.fileManager = FileManagerClient(
                currentDirectoryPath: { "/test" },
                fileExists: { _ in false },
                createDirectory: { _, _ in },
                removeItem: { _ in },
                writeData: { _, _ in },
                readData: { _ in Data() }
            )
        } operation: {
            let config = FuzzEngine<String>.Config(
                maxIterations: 100,
                maxDuration: 5,
                verbose: false
            )

            let engine = FuzzEngine<String>(config: config, corpusDirectory: corpusDir)

            return engine.run(additionalSeeds: numberParserSeeds) { input in
                if !NumberParser.negationProperty(input) {
                    negationFailures.append(input)
                }
            }
        }

        print("Negation property: \(result.stats.totalInputs) inputs, \(result.corpus.count) paths")
        #expect(result.failures.isEmpty)
        #expect(negationFailures.isEmpty, "Negation property failures: \(negationFailures)")
    }

    @Test("FuzzEngine saves corpus after run")
    func testFuzzEngineSavesCorpus() throws {
        let corpusDir = URL(fileURLWithPath: "/test/fuzz-persist")
        let (writeDataSpy, writeDataFn) = spy { (_: Data, _: URL) in }

        withDependencies {
            $0.fileManager = FileManagerClient(
                currentDirectoryPath: { "/test" },
                fileExists: { _ in false },
                createDirectory: { _, _ in },
                removeItem: { _ in },
                writeData: writeDataFn,
                readData: { _ in Data() }
            )
        } operation: {
            let config = FuzzEngine<String>.Config(
                maxIterations: 50,
                maxDuration: 5,
                plateauThreshold: 30,
                verbose: false
            )

            let engine = FuzzEngine<String>(config: config, corpusDirectory: corpusDir)
            let result = engine.run(additionalSeeds: numberParserSeeds) { input in
                _ = NumberParser.parse(input)
            }

            #expect(!result.wasRegression, "First run should be fuzzing mode")
            #expect(result.corpus.count > 0, "Should have corpus entries")
            #expect(result.failures.isEmpty, "Should have no failures")
        }

        // Verify corpus was saved
        #expect(writeDataSpy.callCount == 1, "Corpus should be saved")
        #expect(writeDataSpy.callParams[0].1.lastPathComponent == "corpus.json")
    }

    @Test("Public fuzz API with custom seeds")
    func testPublicFuzzAPIWithSeeds() throws {
        // Demonstrates the simplified public API with custom seeds
        var inputCount = 0

        try withDependencies {
            $0.fileManager = FileManagerClient(
                currentDirectoryPath: { "/test" },
                fileExists: { _ in false },
                createDirectory: { _, _ in },
                removeItem: { _ in },
                writeData: { _, _ in },
                readData: { _ in Data() }
            )
        } operation: {
            try fuzz(
                seeds: ["0", "-0", "-1", "abc", String(Int.max)],
                iterations: 50,
                duration: 5
            ) { (input: String) in
                inputCount += 1
                let parsed = NumberParser.parse(input)

                // Property: round-trip should work
                if let n = parsed {
                    let reparsed = NumberParser.parse(String(n))
                    #expect(reparsed == n, "Round-trip failed for \(input)")
                }
            }
        }

        print("Public API tested \(inputCount) inputs")
        #expect(inputCount > 0)
    }

    @Test("FuzzError errorDescription covers all cases")
    func testFuzzErrorDescriptions() {
        // Test .testFailed
        let testFailedError = FuzzError.testFailed(
            input: "badInput",
            underlyingError: NSError(domain: "test", code: 1)
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
    func testConfigFromEnvironment() {
        withDependencies {
            $0.environment = EnvironmentClient(environment: {
                [
                    "FUZZ_ITERATIONS": "500",
                    "FUZZ_DURATION": "30",
                    "FUZZ_VERBOSE": "1"
                ]
            })
        } operation: {
            let config: FuzzEngine<String>.Config = .fromEnvironment()

            #expect(config.maxIterations == 500)
            #expect(config.maxDuration == 30)
            #expect(config.verbose == true)
        }
    }

    @Test("Config.fromEnvironment uses defaults when env vars not set")
    func testConfigFromEnvironmentDefaults() {
        withDependencies {
            $0.environment = EnvironmentClient(environment: { [:] })
        } operation: {
            let config: FuzzEngine<String>.Config = .fromEnvironment()

            #expect(config.maxIterations == 10_000)
            #expect(config.maxDuration == 60)
            #expect(config.verbose == false)
        }
    }

    @Test("FuzzEngine captures failures correctly")
    func testFuzzEngineFailureCapture() throws {
        // Create an error to throw
        struct TestFailure: Error {}

        // Test FuzzEngine directly to verify failure capture without Issue.record noise
        let config = FuzzEngine<Bool>.Config(
            maxIterations: 10,
            maxDuration: 5,
            verbose: false
        )

        let engine = FuzzEngine<Bool>(config: config)
        let result = engine.run { input in
            // Throw for any input to guarantee a failure
            throw TestFailure()
        }

        // Verify failures were captured
        #expect(!result.failures.isEmpty, "Should have captured failures")

        // Verify the error type
        if let (_, error) = result.failures.first {
            #expect(error is TestFailure, "Error should be TestFailure")
        }
    }

    @Test("fuzz() records issues and throws on failure")
    func testFuzzRecordsIssuesOnFailure() throws {
        struct TestFailure: Error {}

        // Use withKnownIssue to expect the recorded issues from fuzz()
        withKnownIssue {
            try withDependencies {
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
                _ = try fuzz(iterations: 10, duration: 5) { (input: Bool) in
                    throw TestFailure()
                }
            }
        }
    }
}
