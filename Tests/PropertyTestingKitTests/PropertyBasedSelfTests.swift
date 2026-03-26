//
//  PropertyBasedSelfTests.swift
//  PropertyTestingKit
//
//  Property-based tests for PropertyTestingKit itself.
//  Using the library to test the library - dogfooding!
//

import Testing
import Foundation
import Dependencies
import FunctionSpy
@testable import PropertyTestingKit

// MARK: - CoverageSignature Property Tests

@Suite("CoverageSignature Properties")
struct CoverageSignaturePropertyTests {

    // MARK: - Signature Algebra Properties

    @Test("Signature union is commutative")
    func testUnionCommutative() async throws {
        // Property: A ∪ B = B ∪ A
        let sig1 = CoverageSignature(edges: Set<UInt32>([0, 1, 2]))
        let sig2 = CoverageSignature(edges: Set<UInt32>([1, 2, 3]))

        let union1 = sig1.union(with: sig2)
        let union2 = sig2.union(with: sig1)

        #expect(union1 == union2, "Union should be commutative")
    }

    @Test("Signature union is associative")
    func testUnionAssociative() async throws {
        // Property: (A ∪ B) ∪ C = A ∪ (B ∪ C)
        let sig1 = CoverageSignature(edges: Set<UInt32>([0, 1]))
        let sig2 = CoverageSignature(edges: Set<UInt32>([1, 2]))
        let sig3 = CoverageSignature(edges: Set<UInt32>([2, 3]))

        let leftAssoc = sig1.union(with: sig2).union(with: sig3)
        let rightAssoc = sig1.union(with: sig2.union(with: sig3))

        #expect(leftAssoc == rightAssoc, "Union should be associative")
    }

    @Test("Signature union with empty is identity")
    func testUnionIdentity() async throws {
        let sig = CoverageSignature(edges: Set<UInt32>([0, 5, 10]))
        let empty = CoverageSignature(edges: Set<UInt32>([]))

        #expect(sig.union(with: empty) == sig, "Union with empty should be identity")
        #expect(empty.union(with: sig) == sig, "Empty union with sig should be identity")
    }

    @Test("Signature union combines all edges")
    func testUnionCombinesEdges() async throws {
        let sig1 = CoverageSignature(edges: Set<UInt32>([0, 1, 2]))
        let sig2 = CoverageSignature(edges: Set<UInt32>([2, 3, 4]))

        let union = sig1.union(with: sig2)

        #expect(union.edges == Set([0, 1, 2, 3, 4]), "Union should contain all edges from both")
    }

    @Test("uniqueIndices and commonIndices are complementary")
    func testIndexSetOperations() async throws {
        let sig1 = CoverageSignature(edges: Set<UInt32>([0, 1, 2]))
        let sig2 = CoverageSignature(edges: Set<UInt32>([1, 2, 3]))

        let unique1 = sig1.uniqueIndices(comparedTo: sig2)
        let unique2 = sig2.uniqueIndices(comparedTo: sig1)
        let common = sig1.commonIndices(with: sig2)

        // Property: unique1 ∩ common = ∅
        #expect(unique1.intersection(common).isEmpty, "Unique and common should be disjoint")
        #expect(unique2.intersection(common).isEmpty, "Unique and common should be disjoint")

        // Property: unique1 ∪ common = sig1.indices
        #expect(unique1.union(common) == sig1.executedIndices, "Unique + common = all indices")
    }

    @Test("hasUniqueCoverage consistent with uniqueIndices")
    func testHasUniqueCoverage() async throws {
        let sig1 = CoverageSignature(edges: Set<UInt32>([0, 1]))
        let sig2 = CoverageSignature(edges: Set<UInt32>([1]))
        let sig3 = CoverageSignature(edges: Set<UInt32>([0, 1]))

        #expect(sig1.hasUniqueCoverage(comparedTo: sig2) == true, "sig1 has index 0 not in sig2")
        #expect(sig2.hasUniqueCoverage(comparedTo: sig1) == false, "sig2 is subset of sig1")
        #expect(sig1.hasUniqueCoverage(comparedTo: sig3) == false, "sig1 indices are subset of sig3")
    }

    // MARK: - Serialization Properties

    @Test("CoverageSignature round-trips through Codable")
    func testSignatureCodableRoundTrip() async throws {
        let signatures = [
            CoverageSignature(edges: Set<UInt32>([])),
            CoverageSignature(edges: Set<UInt32>([0])),
            CoverageSignature(edges: Set<UInt32>([0, 100, 1000])),
        ]

        let encoder = JSONEncoder.corpusEncoder()
        let decoder = JSONDecoder.corpusDecoder()

        for original in signatures {
            let data = try encoder.encode(original)
            let decoded = try decoder.decode(CoverageSignature.self, from: data)
            #expect(decoded == original, "Signature should round-trip through JSON")
        }
    }
}

// MARK: - MutatorProviding Property Tests

@Suite("MutatorProviding Properties")
struct MutatorProvidingPropertyTests {

    @Test("Bool.defaultMutator.mutate always returns the opposite value")
    func testBoolMutate() async throws {
        #expect(Bool.defaultMutator.mutate(true) == [false])
        #expect(Bool.defaultMutator.mutate(false) == [true])
    }

    @Test("Int.defaultMutator.mutate never returns the original value")
    func testIntMutateExcludesOriginal() async throws {
        // Test specific values including edge cases
        let testValues = [0, 1, -1, 42, -42, 1000, -1000, Int.max, Int.min, Int.max / 2, Int.min / 2]

        for n in testValues {
            let mutations = Int.defaultMutator.mutate(n)
            #expect(!mutations.contains(n), "Mutations should not contain original value \(n)")
        }
    }

    @Test("Int.defaultMutator.mutate produces valid mutations without overflow")
    func testIntMutateNoOverflow() async throws {
        // Test edge cases explicitly
        let edgeCases = [Int.max, Int.min, 0, 1, -1]

        for n in edgeCases {
            let mutations = Int.defaultMutator.mutate(n)
            // Should not crash and all mutations should be valid
            for m in mutations {
                #expect(m != n, "Mutation \(m) should differ from original \(n)")
            }
        }
    }

    @Test("String.defaultMutator.mutate never returns the original value")
    func testStringMutateExcludesOriginal() async throws {
        // Test specific values from String.defaultMutator.seeds plus some extras
        let testValues = String.defaultMutator.seeds + ["test", "Hello World", "12345"]

        for s in testValues {
            let mutations = String.defaultMutator.mutate(s)
            #expect(!mutations.contains(s), "Mutations should not contain original value '\(s)'")
        }
    }

    @Test("Optional.defaultMutator.mutate includes nil when value is some")
    func testOptionalMutateIncludesNil() async throws {
        let mutations = Optional<Int>.defaultMutator.mutate(42)
        #expect(mutations.contains(nil), "Mutating some should include nil")
    }

    @Test("Optional.defaultMutator.mutate includes some values when value is nil")
    func testOptionalMutateFromNil() async throws {
        let mutations = Optional<Int>.defaultMutator.mutate(nil)
        #expect(mutations.allSatisfy { $0 != nil }, "Mutating nil should only produce some values")
        #expect(!mutations.isEmpty, "Mutating nil should produce some mutations")
    }

    @Test("Array.defaultMutator.mutate produces structural variations")
    func testArrayMutate() async throws {
        let original = [1, 2, 3]
        let mutations = Array<Int>.defaultMutator.mutate(original)

        // Should include shorter arrays (element removal)
        let hasShorter = mutations.contains { $0.count < original.count }
        #expect(hasShorter, "Should have shorter mutations")

        // Should include longer arrays (element addition)
        let hasLonger = mutations.contains { $0.count > original.count }
        #expect(hasLonger, "Should have longer mutations")

        // Should include reversed
        let hasReversed = mutations.contains([3, 2, 1])
        #expect(hasReversed, "Should include reversed array")
    }

    @Test("UInt.defaultMutator.mutate respects bounds")
    func testUIntMutateBounds() async throws {
        // Test UInt.max - should not overflow
        let maxMutations = UInt.defaultMutator.mutate(UInt.max)
        #expect(!maxMutations.isEmpty, "Should have mutations for UInt.max")
        #expect(!maxMutations.contains(UInt.max), "Should not contain original")

        // Test 0 - should not underflow
        let zeroMutations = UInt.defaultMutator.mutate(0)
        #expect(!zeroMutations.isEmpty, "Should have mutations for 0")
        #expect(!zeroMutations.contains(0), "Should not contain original")
    }

    @Test("Double.defaultMutator.mutate handles special values")
    func testDoubleMutateSpecialValues() async throws {
        // NaN should produce finite mutations
        let nanMutations = Double.defaultMutator.mutate(Double.nan)
        #expect(nanMutations.allSatisfy { $0.isFinite }, "NaN mutations should be finite")

        // Infinity should produce finite mutations
        let infMutations = Double.defaultMutator.mutate(Double.infinity)
        #expect(infMutations.allSatisfy { $0.isFinite }, "Infinity mutations should be finite")
    }

    @Test("Character.defaultMutator.mutate returns all other fuzz characters")
    func testCharacterMutate() async throws {
        let mutations = Character.defaultMutator.mutate("a")
        #expect(!mutations.contains("a" as Character), "Should not contain original")
        #expect(mutations.count == Character.defaultMutator.seeds.count - 1, "Should have all other fuzz chars")
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

    @Test("Corpus minimization preserves total coverage")
    func testMinimizationPreservesCoverage() throws {
        var corpus = Corpus<String>()

        // Add entries with overlapping coverage
        corpus.add(input: ("a"), sparse: SparseCoverage(indices: [0, 1]))
        corpus.add(input: ("b"), sparse: SparseCoverage(indices: [1, 2]))
        corpus.add(input: ("c"), sparse: SparseCoverage(indices: [2, 3]))
        corpus.add(input: ("d"), sparse: SparseCoverage(indices: [0, 1]))  // Redundant

        let originalCoverage = corpus.coveredIndices
        let minimized = corpus.minimized()
        let count = corpus.count

        // Property: minimized coverage equals original coverage
        #expect(
            minimized.coveredIndices == originalCoverage,
            "Minimization should preserve coverage indices"
        )

        // Property: minimized should have fewer or equal entries
        #expect(minimized.count <= count, "Minimized should not be larger")
    }

    @Test("Corpus handles empty minimization")
    func testEmptyMinimization() throws {
        var corpus = Corpus<String>()
        let minimized = corpus.minimized()
        #expect(minimized.isEmpty, "Minimized empty corpus should be empty")
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

    @Test("Corpus minimization with no new coverage")
    func testMinimizationNoNewCoverage() throws {
        var corpus = Corpus<String>()

        // Add one entry that covers everything
        corpus.add(input: ("all"), sparse: SparseCoverage(indices: [0, 1, 2]))

        // Add more entries that cover subsets (will have bestCoverage = 0 after first)
        corpus.add(input: ("sub1"), sparse: SparseCoverage(indices: [0]))
        corpus.add(input: ("sub2"), sparse: SparseCoverage(indices: [1]))

        let minimized = corpus.minimized()
        let totalCoverage = corpus.coveredIndices

        // The first entry should cover everything, so minimization should pick just that one
        #expect(minimized.count >= 1, "Should have at least one entry")
        #expect(
            minimized.coveredIndices == totalCoverage,
            "Coverage should be preserved"
        )
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

// MARK: - Integration Property Tests

@Suite("Integration Properties")
struct IntegrationPropertyTests {

    @Test("Signature from sparse coverage contains only specified indices")
    func testSignatureFromSparseCoverage() async throws {
        // SparseCoverage only contains the indices that were covered
        let sparse = SparseCoverage(indices: [1, 3, 6])
        let signature = CoverageSignature(sparse: sparse)

        #expect(signature.executedCount == 3, "Should have 3 covered edges")
        #expect(!signature.edges.contains(0), "Index 0 should not be in edges")
        #expect(signature.edges.contains(1), "Index 1 should be in edges")
        #expect(signature.edges.contains(3), "Index 3 should be in edges")
        #expect(signature.edges.contains(6), "Index 6 should be in edges")
    }
}

// MARK: - FuzzError Tests

@Suite("FuzzError Properties")
struct FuzzErrorTests {

    @Test("FuzzError.testFailed has correct description")
    func testTestFailedDescription() async throws {
        let error = FuzzError.testFailed(input: "test input", underlyingError: NSError(domain: "test", code: 1), timeElapsed: 0, stats: FuzzStats(totalInputs: 0, mutations: 0, generations: 0, duration: 0))
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

    @Test("Signature with many indices")
    func testManyIndices() async throws {
        let edges = Set((0..<1000).map { UInt32($0) })
        let sig = CoverageSignature(edges: edges)

        #expect(sig.executedCount == 1000)
        #expect(!sig.isEmpty)

        // Union with self should be idempotent
        let selfUnion = sig.union(with: sig)
        #expect(selfUnion == sig)
    }

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

        // Test minimization
        let minimized = corpus.minimized()
        #expect(minimized.count <= count)
    }

    @Test("CoverageSignature description")
    func testSignatureDescription() async throws {
        let sig = CoverageSignature(edges: Set<UInt32>([0, 1, 2]))
        #expect(sig.description == "CoverageSignature(3 edges)")

        let empty = CoverageSignature(edges: Set<UInt32>([]))
        #expect(empty.description == "CoverageSignature(0 edges)")
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
            $0.fileManager = FileManagerClient(
                currentDirectoryPath: { "/test" },
                fileExists: { _ in false },
                createDirectory: { _, _ in },
                removeItem: { _ in },
                writeData: { _, _ in },
                readData: { _ in Data() }
            )
        } operation: {
            // Use refuzzReplace to always start fresh (ignore any saved corpus)
            try await fuzzWithMaxIterations(
                maxIterations: 50,
                seeds: ["custom1", "custom2", "custom3"],
                corpusMode: .refuzzReplace,
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

