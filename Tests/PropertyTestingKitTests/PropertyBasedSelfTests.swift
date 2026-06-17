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

//  Property-based tests for PropertyTestingKit itself.
//  Using the library to test the library - dogfooding!
//

import Testing
import Foundation
import Dependencies
import FunctionSpy
@testable import PropertyTestingKit

// MARK: - MutatorProviding Property Tests

@Suite("MutatorProviding Properties")
struct MutatorProvidingPropertyTests {

    @Test("Bool.defaultMutator.mutate always returns the opposite value")
    func testBoolMutate() async throws {
        var rng = FastRNG()
        #expect(Bool.defaultMutator.mutate(true, &rng) == false)
        #expect(Bool.defaultMutator.mutate(false, &rng) == true)
    }

    @Test("Int.defaultMutator.mutate never returns the original value")
    func testIntMutateExcludesOriginal() async throws {
        // Test specific values including edge cases
        let testValues = [0, 1, -1, 42, -42, 1000, -1000, Int.max, Int.min, Int.max / 2, Int.min / 2]

        var rng = FastRNG()
        for n in testValues {
            for _ in 0..<100 {
                let mutant = Int.defaultMutator.mutate(n, &rng)
                #expect(mutant != n, "Mutant should not equal original value \(n)")
            }
        }
    }

    @Test("Int.defaultMutator.mutate produces valid mutations without overflow")
    func testIntMutateNoOverflow() async throws {
        // Test edge cases explicitly
        let edgeCases = [Int.max, Int.min, 0, 1, -1]

        var rng = FastRNG()
        for n in edgeCases {
            // Should not crash (no overflow trap) and all mutants should be valid
            for _ in 0..<100 {
                let mutant = Int.defaultMutator.mutate(n, &rng)
                #expect(mutant != n, "Mutant \(mutant) should differ from original \(n)")
            }
        }
    }

    @Test("String.defaultMutator.mutate never returns the original value")
    func testStringMutateExcludesOriginal() async throws {
        // Test specific values from String.defaultMutator.seeds plus some extras
        let testValues = String.defaultMutator.seeds + ["test", "Hello World", "12345"]

        var rng = FastRNG()
        for s in testValues {
            for _ in 0..<100 {
                let mutant = String.defaultMutator.mutate(s, &rng)
                #expect(mutant != s, "Mutant should not equal original value '\(s)'")
            }
        }
    }

    @Test("Optional.defaultMutator.mutate draws nil when value is some")
    func testOptionalMutateIncludesNil() async throws {
        var rng = FastRNG()
        var seen = Set<Int?>()
        for _ in 0..<200 { seen.insert(Optional<Int>.defaultMutator.mutate(42, &rng)) }
        #expect(seen.contains(nil), "Mutating some should sometimes draw nil")
    }

    @Test("Optional.defaultMutator.mutate returns some values when value is nil")
    func testOptionalMutateFromNil() async throws {
        var rng = FastRNG()
        for _ in 0..<200 {
            let mutant = Optional<Int>.defaultMutator.mutate(nil, &rng)
            #expect(mutant != nil, "Mutating nil should only produce some values")
        }
    }

    @Test("Array.defaultMutator.mutate draws structural variations")
    func testArrayMutate() async throws {
        let original = [1, 2, 3]

        var rng = FastRNG()
        var seen = Set<[Int]>()
        for _ in 0..<200 { seen.insert(Array<Int>.defaultMutator.mutate(original, &rng)) }

        // Should include shorter arrays (element removal)
        let hasShorter = seen.contains { $0.count < original.count }
        #expect(hasShorter, "Should draw shorter mutations")

        // Should include longer arrays (element addition)
        let hasLonger = seen.contains { $0.count > original.count }
        #expect(hasLonger, "Should draw longer mutations")

        // Should include reversed
        let hasReversed = seen.contains([3, 2, 1])
        #expect(hasReversed, "Should draw reversed array")
    }

    @Test("UInt.defaultMutator.mutate respects bounds")
    func testUIntMutateBounds() async throws {
        var rng = FastRNG()

        // Test UInt.max - should not overflow
        for _ in 0..<100 {
            let mutant = UInt.defaultMutator.mutate(UInt.max, &rng)
            #expect(mutant != UInt.max, "Should not return original")
        }

        // Test 0 - should not underflow
        for _ in 0..<100 {
            let mutant = UInt.defaultMutator.mutate(0, &rng)
            #expect(mutant != 0, "Should not return original")
        }
    }

    @Test("Double.defaultMutator.mutate handles special values")
    func testDoubleMutateSpecialValues() async throws {
        var rng = FastRNG()

        // NaN should produce finite mutations
        for _ in 0..<100 {
            let mutant = Double.defaultMutator.mutate(Double.nan, &rng)
            #expect(mutant.isFinite, "NaN mutants should be finite")
        }

        // Infinity should produce finite mutations
        for _ in 0..<100 {
            let mutant = Double.defaultMutator.mutate(Double.infinity, &rng)
            #expect(mutant.isFinite, "Infinity mutants should be finite")
        }
    }

    @Test("Character.defaultMutator.mutate draws every other fuzz character")
    func testCharacterMutate() async throws {
        var rng = FastRNG()
        var seen = Set<Character>()
        for _ in 0..<200 { seen.insert(Character.defaultMutator.mutate("a", &rng)) }

        // Never the original; across draws, covers all other fuzz chars
        let others = Set(Character.defaultMutator.seeds.filter { $0 != "a" })
        #expect(seen == others, "Should draw exactly the other fuzz chars, never the original")
    }
}

// MARK: - Corpus Property Tests

@Suite("Corpus Properties")
struct CorpusPropertyTests {

    @Test("Corpus addIfInteresting uses signature-based uniqueness")
    func testAddIfInterestingSignatureBasedUniqueness() throws {
        var corpus = Corpus<String>()
        var signatureHashes = Set<Int>()

        let sparse1 = SparseCoverage(indices: [0, 1, 2])

        // First add should succeed
        let added1 = corpus.addIfInteresting(input: ("first"), sparse: sparse1, signatureHashes: &signatureHashes)
        #expect(added1 == true, "First entry should be added")

        // Different signature (subset) IS interesting - represents a different code path
        let sparseSubset = SparseCoverage(indices: [0, 1])
        let added2 = corpus.addIfInteresting(input: ("subset"), sparse: sparseSubset, signatureHashes: &signatureHashes)
        #expect(added2 == true, "Different signature should be accepted (unique code path)")

        // Same signature as first should be rejected
        let sparseSame = SparseCoverage(indices: [0, 1, 2])
        let added3 = corpus.addIfInteresting(input: ("same"), sparse: sparseSame, signatureHashes: &signatureHashes)
        #expect(added3 == false, "Identical signature should be rejected")

        // Different signature with new edges should be accepted
        let sparseNew = SparseCoverage(indices: [3])
        let added4 = corpus.addIfInteresting(input: ("new"), sparse: sparseNew, signatureHashes: &signatureHashes)
        #expect(added4 == true, "New signature should be accepted")
    }

    @Test("Corpus isEmpty property")
    func testCorpusIsEmpty() throws {
        var corpus = Corpus<String>()
        var isEmpty = corpus.isEmpty
        #expect(isEmpty, "New corpus should be empty")

        corpus.add(input: ("a"), sparse: SparseCoverage(indices: [0]))
        isEmpty = corpus.isEmpty
        #expect(!isEmpty, "Corpus with entry should not be empty")
    }

    @Test("Corpus inputs property")
    func testCorpusInputs() throws {
        var corpus = Corpus<String>()

        corpus.add(input: ("hello"), sparse: SparseCoverage(indices: [0]))
        corpus.add(input: ("world"), sparse: SparseCoverage(indices: [1]))

        let inputs = corpus.inputs
        #expect(inputs.count == 2, "Should have 2 inputs")
        #expect(inputs[0] == "hello", "First input should match")
        #expect(inputs[1] == "world", "Second input should match")
    }

}

// MARK: - CorpusEntry Property Tests

@Suite("CorpusEntry Properties")
struct CorpusEntryPropertyTests {

    @Test("CorpusEntry preserves input through Codable")
    func testCorpusEntryCodable() async throws {
        let entry = CorpusEntry(
            input: "test input",
            sparseCoverage: SparseCoverage(indices: [0, 5]),
            entryType: .coverage,
            failure: nil
        )

        let encoder = JSONEncoder.corpusEncoder()
        let decoder = JSONDecoder.corpusDecoder()

        let data = try encoder.encode(entry)
        let decoded = try decoder.decode(CorpusEntry<String>.self, from: data)

        #expect(decoded.input == entry.input)
        #expect(decoded.sparseCoverage == SparseCoverage(), "Coverage is not persisted")
        #expect(decoded.entryType == .coverage, "Defaults to .coverage on decode")
        #expect(decoded.failure == nil)
    }
}

// MARK: - FuzzError Tests

@Suite("FuzzError Properties")
struct FuzzErrorTests {

    @Test("FuzzError.testFailed has correct description")
    func testTestFailedDescription() async throws {
        let error = FuzzError.testFailed(input: "test input", underlyingError: NSError(domain: "test", code: 1), timeElapsed: 0, stats: FuzzStats(totalInputs: 0, seeds: 0, mutations: 0, generations: 0, duration: 0))
        let desc = error.errorDescription ?? ""
        #expect(desc.contains("test input"))
        #expect(desc.contains("Fuzz test failed"))
    }

    @Test("FuzzError.coverageUnavailable has correct description")
    func testCoverageUnavailableDescription() async throws {
        let error = FuzzError.coverageUnavailable
        let desc = error.errorDescription ?? ""
        #expect(desc.contains("Coverage instrumentation"))
    }

    @Test("FuzzError.corpusError has correct description")
    func testCorpusErrorDescription() async throws {
        let error = FuzzError.corpusError("test message")
        let desc = error.errorDescription ?? ""
        #expect(desc.contains("test message"))
        #expect(desc.contains("Corpus error"))
    }
}

// MARK: - Edge Case Tests

@Suite("Edge Cases")
struct EdgeCaseTests {

    @Test("Corpus with complex input types")
    func testCorpusComplexTypes() throws {
        var corpus = Corpus<[String]>()

        corpus.add(
            input: (["a", "b", "c"]),
            sparse: SparseCoverage(indices: [0])
        )
        corpus.add(
            input: ([]),
            sparse: SparseCoverage(indices: [1])
        )
        corpus.add(
            input: (["single"]),
            sparse: SparseCoverage(indices: [2])
        )

        let count = corpus.count
        #expect(count == 3)
    }

}

// MARK: - Fuzz API Property Tests

@Suite("Fuzz API Properties")
struct FuzzAPIPropertyTests {

    @Test("fuzz function runs with default configuration")
    func testFuzzDefaultConfig() async throws {
        // Use a simple test that won't fail
        let result = try await withDependencies {
            $0.fileManager = FileManagerClient(
                currentDirectoryPath: { "/test" },
                fileExists: { _ in false },
                createDirectory: { _, _ in },
                removeItem: { _ in },
                writeData: { _, _ in },
                readData: { _ in Data() }
            )
            $0.environment = EnvironmentClient(environment: { [:] })
        } operation: {
            try await fuzzWithMaxIterations(
                maxIterations: 50,
                persistence: .ephemeral,
                coverageStrategy: .alwaysInteresting
            ) { (input: Int) in
                _ = input > 0 ? "positive" : "non-positive"
            }
        }

        #expect(result.stats.totalInputs > 0)
        #expect(result.failures.isEmpty)
    }

    @Test("fuzz function accepts custom seeds")
    func testFuzzWithCustomSeeds() async throws {
        let result = try await withDependencies {
            $0.environment = EnvironmentClient(environment: { [:] })
        } operation: {
            // Ephemeral: fuzz fresh in memory, ignoring and never writing a corpus.
            try await fuzzWithMaxIterations(
                maxIterations: 50,
                seeds: ["custom1", "custom2", "custom3"],
                persistence: .ephemeral,
                coverageStrategy: .alwaysInteresting
            ) { (input: String) in
                // Just exercise the input - no actor involvement
                _ = input.count
            }
        }

        // Check that fuzz ran and processed seeds via stats
        // String.fuzz has 21 values + 3 custom = 24 seeds minimum
        #expect(result.stats.totalInputs >= 24, "Should process all seeds (got \(result.stats.totalInputs))")

        // Also check corpus has entries (since alwaysInteresting strategy adds everything)
        #expect(result.corpus.count > 0, "Corpus should have entries")
    }

}

