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
        let sig1 = CoverageSignature(edges: [0, 1, 2])
        let sig2 = CoverageSignature(edges: [1, 2, 3])

        let union1 = sig1.union(with: sig2)
        let union2 = sig2.union(with: sig1)

        #expect(union1 == union2, "Union should be commutative")
    }

    @Test("Signature union is associative")
    func testUnionAssociative() async throws {
        // Property: (A ∪ B) ∪ C = A ∪ (B ∪ C)
        let sig1 = CoverageSignature(edges: [0, 1])
        let sig2 = CoverageSignature(edges: [1, 2])
        let sig3 = CoverageSignature(edges: [2, 3])

        let leftAssoc = sig1.union(with: sig2).union(with: sig3)
        let rightAssoc = sig1.union(with: sig2.union(with: sig3))

        #expect(leftAssoc == rightAssoc, "Union should be associative")
    }

    @Test("Signature union with empty is identity")
    func testUnionIdentity() async throws {
        let sig = CoverageSignature(edges: [0, 5, 10])
        let empty = CoverageSignature(edges: [])

        #expect(sig.union(with: empty) == sig, "Union with empty should be identity")
        #expect(empty.union(with: sig) == sig, "Empty union with sig should be identity")
    }

    @Test("Signature union combines all edges")
    func testUnionCombinesEdges() async throws {
        let sig1 = CoverageSignature(edges: [0, 1, 2])
        let sig2 = CoverageSignature(edges: [2, 3, 4])

        let union = sig1.union(with: sig2)

        #expect(union.edges == Set([0, 1, 2, 3, 4]), "Union should contain all edges from both")
    }

    @Test("uniqueIndices and commonIndices are complementary")
    func testIndexSetOperations() async throws {
        let sig1 = CoverageSignature(edges: [0, 1, 2])
        let sig2 = CoverageSignature(edges: [1, 2, 3])

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
        let sig1 = CoverageSignature(edges: [0, 1])
        let sig2 = CoverageSignature(edges: [1])
        let sig3 = CoverageSignature(edges: [0, 1])

        #expect(sig1.hasUniqueCoverage(comparedTo: sig2) == true, "sig1 has index 0 not in sig2")
        #expect(sig2.hasUniqueCoverage(comparedTo: sig1) == false, "sig2 is subset of sig1")
        #expect(sig1.hasUniqueCoverage(comparedTo: sig3) == false, "sig1 indices are subset of sig3")
    }

    // MARK: - Serialization Properties

    @Test("CoverageSignature round-trips through Codable")
    func testSignatureCodableRoundTrip() async throws {
        let signatures = [
            CoverageSignature(edges: []),
            CoverageSignature(edges: [0]),
            CoverageSignature(edges: [0, 100, 1000]),
        ]

        let encoder = JSONEncoder.corpusEncoder
        let decoder = JSONDecoder.corpusDecoder

        for original in signatures {
            let data = try encoder.encode(original)
            let decoded = try decoder.decode(CoverageSignature.self, from: data)
            #expect(decoded == original, "Signature should round-trip through JSON")
        }
    }
}

// MARK: - SignatureSet Property Tests

@Suite("SignatureSet Properties")
struct SignatureSetPropertyTests {

    @Test("SignatureSet insert returns correct newness")
    func testInsertNewness() async throws {
        var set = SignatureSet()

        let sig1 = CoverageSignature(edges: [0])
        let sig2 = CoverageSignature(edges: [0])  // Duplicate
        let sig3 = CoverageSignature(edges: [1])  // New

        #expect(set.insert(sig1) == true, "First insert should be new")
        #expect(set.insert(sig2) == false, "Duplicate insert should not be new")
        #expect(set.insert(sig3) == true, "Different signature should be new")
    }

    @Test("SignatureSet totalCoverage is union of all signatures")
    func testTotalCoverageIsUnion() async throws {
        var set = SignatureSet()

        let sig1 = CoverageSignature(edges: [0, 1])
        let sig2 = CoverageSignature(edges: [2, 3])

        set.insert(sig1)
        set.insert(sig2)

        let expectedTotal = sig1.union(with: sig2)
        #expect(set.totalCoverage == expectedTotal, "Total coverage should be union")
    }

    @Test("wouldAddNewCoverage is consistent with totalCoverage")
    func testWouldAddNewCoverage() async throws {
        var set = SignatureSet()

        let sig1 = CoverageSignature(edges: [0, 1])
        set.insert(sig1)

        let subsetSig = CoverageSignature(edges: [0])
        let newSig = CoverageSignature(edges: [2])

        #expect(set.wouldAddNewCoverage(subsetSig) == false, "Subset should not add new coverage")
        #expect(set.wouldAddNewCoverage(newSig) == true, "New index should add coverage")
    }
}

// MARK: - Fuzzable Conformance Property Tests

@Suite("Fuzzable Properties")
struct FuzzablePropertyTests {

    @Test("Bool.mutate always returns the opposite value")
    func testBoolMutate() async throws {
        #expect(true.mutate() == [false])
        #expect(false.mutate() == [true])
    }

    @Test("Int.mutate never returns the original value")
    func testIntMutateExcludesOriginal() async throws {
        // Test specific values including edge cases
        let testValues = [0, 1, -1, 42, -42, 1000, -1000, Int.max, Int.min, Int.max / 2, Int.min / 2]

        for n in testValues {
            let mutations = n.mutate()
            #expect(!mutations.contains(n), "Mutations should not contain original value \(n)")
        }
    }

    @Test("Int.mutate produces valid mutations without overflow")
    func testIntMutateNoOverflow() async throws {
        // Test edge cases explicitly
        let edgeCases = [Int.max, Int.min, 0, 1, -1]

        for n in edgeCases {
            let mutations = n.mutate()
            // Should not crash and all mutations should be valid
            for m in mutations {
                #expect(m != n, "Mutation \(m) should differ from original \(n)")
            }
        }
    }

    @Test("String.mutate never returns the original value")
    func testStringMutateExcludesOriginal() async throws {
        // Test specific values from String.fuzz plus some extras
        let testValues = String.fuzz + ["test", "Hello World", "12345"]

        for s in testValues {
            let mutations = s.mutate()
            #expect(!mutations.contains(s), "Mutations should not contain original value '\(s)'")
        }
    }

    @Test("Optional.mutate includes nil when value is some")
    func testOptionalMutateIncludesNil() async throws {
        let mutations = (Optional<Int>.some(42)).mutate()
        #expect(mutations.contains(nil), "Mutating some should include nil")
    }

    @Test("Optional.mutate includes some values when value is nil")
    func testOptionalMutateFromNil() async throws {
        let mutations = (nil as Int?).mutate()
        #expect(mutations.allSatisfy { $0 != nil }, "Mutating nil should only produce some values")
        #expect(!mutations.isEmpty, "Mutating nil should produce some mutations")
    }

    @Test("Array.mutate produces structural variations")
    func testArrayMutate() async throws {
        let original = [1, 2, 3]
        let mutations = original.mutate()

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

    @Test("UInt.mutate respects bounds")
    func testUIntMutateBounds() async throws {
        // Test UInt.max - should not overflow
        let maxMutations = (UInt.max).mutate()
        #expect(!maxMutations.isEmpty, "Should have mutations for UInt.max")
        #expect(!maxMutations.contains(UInt.max), "Should not contain original")

        // Test 0 - should not underflow
        let zeroMutations = (0 as UInt).mutate()
        #expect(!zeroMutations.isEmpty, "Should have mutations for 0")
        #expect(!zeroMutations.contains(0), "Should not contain original")
    }

    @Test("Double.mutate handles special values")
    func testDoubleMutateSpecialValues() async throws {
        // NaN should produce finite mutations
        let nanMutations = (Double.nan).mutate()
        #expect(nanMutations.allSatisfy { $0.isFinite }, "NaN mutations should be finite")

        // Infinity should produce finite mutations
        let infMutations = (Double.infinity).mutate()
        #expect(infMutations.allSatisfy { $0.isFinite }, "Infinity mutations should be finite")
    }

    @Test("Character.mutate returns all other fuzz characters")
    func testCharacterMutate() async throws {
        let mutations = ("a" as Character).mutate()
        #expect(!mutations.contains("a" as Character), "Should not contain original")
        #expect(mutations.count == Character.fuzz.count - 1, "Should have all other fuzz chars")
    }
}

// MARK: - Corpus Property Tests

@Suite("Corpus Properties")
struct CorpusPropertyTests {

    @Test("Corpus addIfInteresting rejects redundant coverage")
    func testAddIfInterestingRejectsRedundant() async throws {
        let corpus = Corpus<String>(schemaVersion: "test")

        let sig1 = CoverageSignature(edges: [0, 1, 2])

        // First add should succeed
        let added1 = await corpus.addIfInteresting(input: "first", signature: sig1)
        #expect(added1 == true, "First entry should be added")

        // Subset signature should be rejected
        let sigSubset = CoverageSignature(edges: [0, 1])
        let added2 = await corpus.addIfInteresting(input: "subset", signature: sigSubset)
        #expect(added2 == false, "Subset coverage should be rejected")

        // New coverage should be accepted
        let sigNew = CoverageSignature(edges: [3])
        let added3 = await corpus.addIfInteresting(input: "new", signature: sigNew)
        #expect(added3 == true, "New coverage should be accepted")
    }

    @Test("Corpus minimization preserves total coverage")
    func testMinimizationPreservesCoverage() async throws {
        let corpus = Corpus<String>(schemaVersion: "test")

        // Add entries with overlapping coverage
        await corpus.add(input: "a", signature: CoverageSignature(edges: [0, 1]))
        await corpus.add(input: "b", signature: CoverageSignature(edges: [1, 2]))
        await corpus.add(input: "c", signature: CoverageSignature(edges: [2, 3]))
        await corpus.add(input: "d", signature: CoverageSignature(edges: [0, 1]))  // Redundant

        let originalCoverage = await corpus.totalCoverage
        let minimized = await corpus.minimized()
        let count = await corpus.count

        // Property: minimized coverage equals original coverage
        #expect(
            minimized.totalCoverage.executedIndices == originalCoverage.executedIndices,
            "Minimization should preserve coverage indices"
        )

        // Property: minimized should have fewer or equal entries
        #expect(minimized.count <= count, "Minimized should not be larger")
    }

    @Test("Corpus selectForMutation returns valid indices")
    func testSelectForMutationValidIndex() async throws {
        let corpus = Corpus<String>(schemaVersion: "test")

        // Empty corpus should return nil
        let emptySelection = await corpus.selectForMutation()
        #expect(emptySelection == nil, "Empty corpus should return nil")

        // Add some entries
        await corpus.add(input: "a", signature: CoverageSignature(edges: [0]))
        await corpus.add(input: "b", signature: CoverageSignature(edges: [1]))
        await corpus.add(input: "c", signature: CoverageSignature(edges: [2]))

        // Selection should be valid index
        let entries = await corpus.entries
        for _ in 0..<10 {
            if let index = await corpus.selectForMutation() {
                #expect(entries.indices.contains(index), "Selected index should be valid")
            }
        }
    }

    @Test("Corpus handles empty minimization")
    func testEmptyMinimization() async throws {
        let corpus = Corpus<String>(schemaVersion: "test")
        let minimized = await corpus.minimized()
        #expect(minimized.isEmpty, "Minimized empty corpus should be empty")
    }

    @Test("Corpus isEmpty property")
    func testCorpusIsEmpty() async throws {
        let corpus = Corpus<String>(schemaVersion: "test")
        var isEmpty = await corpus.isEmpty
        #expect(isEmpty, "New corpus should be empty")

        await corpus.add(input: "a", signature: CoverageSignature(edges: [0]))
        isEmpty = await corpus.isEmpty
        #expect(!isEmpty, "Corpus with entry should not be empty")
    }

    @Test("Corpus signatures property")
    func testCorpusSignatures() async throws {
        let corpus = Corpus<String>(schemaVersion: "test")

        let sig1 = CoverageSignature(edges: [0])
        let sig2 = CoverageSignature(edges: [1])

        await corpus.add(input: "a", signature: sig1)
        await corpus.add(input: "b", signature: sig2)

        let signatures = await corpus.signatures
        #expect(signatures.count == 2, "Should have 2 signatures")
        #expect(signatures[0] == sig1, "First signature should match")
        #expect(signatures[1] == sig2, "Second signature should match")
    }

    @Test("Corpus inputs property")
    func testCorpusInputs() async throws {
        let corpus = Corpus<String>(schemaVersion: "test")

        await corpus.add(input: "hello", signature: CoverageSignature(edges: [0]))
        await corpus.add(input: "world", signature: CoverageSignature(edges: [1]))

        let inputs = await corpus.inputs
        #expect(inputs.count == 2, "Should have 2 inputs")
        #expect(inputs[0] == "hello", "First input should match")
        #expect(inputs[1] == "world", "Second input should match")
    }

    @Test("Corpus selectForMutation with empty signatures")
    func testSelectForMutationEmptySignatures() async throws {
        let corpus = Corpus<String>(schemaVersion: "test")

        // Add entries with empty signatures (totalScore will be 0)
        let emptySig = CoverageSignature(edges: [])
        await corpus.add(input: "a", signature: emptySig)
        await corpus.add(input: "b", signature: emptySig)

        // Should still return a valid index (random selection fallback)
        let index = await corpus.selectForMutation()
        let entries = await corpus.entries
        #expect(index != nil, "Should return an index")
        #expect(entries.indices.contains(index!), "Index should be valid")
    }

    @Test("Corpus minimization with no new coverage")
    func testMinimizationNoNewCoverage() async throws {
        let corpus = Corpus<String>(schemaVersion: "test")

        // Add one entry that covers everything
        await corpus.add(input: "all", signature: CoverageSignature(edges: [0, 1, 2]))

        // Add more entries that cover subsets (will have bestCoverage = 0 after first)
        await corpus.add(input: "sub1", signature: CoverageSignature(edges: [0]))
        await corpus.add(input: "sub2", signature: CoverageSignature(edges: [1]))

        let minimized = await corpus.minimized()
        let totalCoverage = await corpus.totalCoverage

        // The first entry should cover everything, so minimization should pick just that one
        #expect(minimized.count >= 1, "Should have at least one entry")
        #expect(
            minimized.totalCoverage.executedIndices == totalCoverage.executedIndices,
            "Coverage should be preserved"
        )
    }
}

// MARK: - CorpusEntry Property Tests

@Suite("CorpusEntry Properties")
struct CorpusEntryPropertyTests {

    @Test("CorpusEntry preserves all fields through Codable")
    func testCorpusEntryCodable() async throws {
        let entry = CorpusEntry(
            input: "test input",
            signature: CoverageSignature(edges: [0, 5]),
            discoveredAt: Date(),
            parentIndex: 42
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(entry)
        let decoded = try decoder.decode(CorpusEntry<String>.self, from: data)

        #expect(decoded.input == entry.input)
        #expect(decoded.signature == entry.signature)
        #expect(decoded.parentIndex == entry.parentIndex)
        // Date comparison with some tolerance due to serialization
        let timeDiff: Double = decoded.discoveredAt.timeIntervalSince(entry.discoveredAt)
        let withinTolerance: Bool = Swift.abs(timeDiff) < Double(1.0)
        #expect(withinTolerance, "Date should be within 1 second")
    }
}

// MARK: - SanCovDiff Property Tests (via measureSanCoverage)

@Suite("SanCovDiff Properties")
struct SanCovDiffPropertyTests {

    @Test("measureSanCoverage captures code execution")
    func testMeasureSanCoverageCaptures() async throws {
        var executed = false

        let diff = measureSanCoverage {
            executed = true
            _ = [1, 2, 3].map { $0 * 2 }  // Some code to execute
        }

        #expect(executed, "Code should have executed")
        if let diff = diff {
            #expect(diff.hasChanges, "Should have detected changes")
        }
    }

    @Test("measureSanCoverage detects different code paths")
    func testMeasureSanCoverageDifferentPaths() async throws {
        let diff1 = measureSanCoverage {
            _ = "path1".uppercased()
        }

        let diff2 = measureSanCoverage {
            _ = [1, 2, 3].reduce(0, +)
        }

        // Both should detect changes
        if let d1 = diff1, let d2 = diff2 {
            #expect(d1.hasChanges, "Path 1 should have changes")
            #expect(d2.hasChanges, "Path 2 should have changes")
        }
    }

    @Test("SanCovDiff properties are consistent")
    func testSanCovDiffConsistency() async throws {
        let diff = measureSanCoverage {
            // Execute some code with multiple branches
            for i in 0..<10 {
                if i % 2 == 0 {
                    _ = "even"
                } else {
                    _ = "odd"
                }
            }
        }

        if let diff = diff {
            // changedCount should match changedIndices.count
            #expect(diff.changedCount == diff.changedIndices.count)

            // newlyCoveredCount should match newlyCoveredIndices.count
            #expect(diff.newlyCoveredCount == diff.newlyCoveredIndices.count)

            // hasChanges should be consistent with changedIndices
            #expect(diff.hasChanges == !diff.changedIndices.isEmpty)
        }
    }
}

// MARK: - Integration Property Tests

@Suite("Integration Properties")
struct IntegrationPropertyTests {

    @Test("Signature from counters excludes zeros")
    func testSignatureFromCountersExcludesZeros() async throws {
        // Use raw UInt64 array directly
        let rawCounters: [UInt64] = [0, 1, 0, 2, 0, 0, 3]
        let signature = CoverageSignature(counters: rawCounters)

        #expect(signature.executedCount == 3, "Should only count non-zero")
        #expect(!signature.edges.contains(0), "Index 0 (zero count) should not be in edges")
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
        let error = FuzzError.testFailed(input: "test input", underlyingError: NSError(domain: "test", code: 1))
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

// MARK: - Regression Mode Tests

@Suite("Regression Mode")
struct RegressionModeTests {

    @Test("CorpusSchema detects version changes")
    func testSchemaVersioning() async throws {
        // Create a mock client with known counter count
        let (snapshotSpy, snapshotFn) = spy { () async -> SanCovCounters? in
            SanCovCounters(counters: [UInt64](repeating: 0, count: 100))
        }
        let mockClient = CoverageCountersClient(
            snapshot: snapshotFn,
            snapshotCoveredArrays: { SparseCoverage(indices: [], counts: []) },
            reset: {},
            isAvailable: { true },
            beginMeasurement: { SanCovCounters.MeasurementContext.testInstance() },
            endMeasurement: { _ in },
            resetWithContext: { _ in },
            snapshotCoveredArraysWithContext: { _ in SparseCoverage(indices: [], counts: []) }
        )
        let version1 = await CorpusSchema.currentVersion(using: mockClient)

        // Version should be in expected format
        #expect(version1 == "v1-100", "Version should be 'v1-100' for 100 counters")

        // Should be compatible with itself
        let isCompatible = await withDependencies {
            $0.coverageCounters = mockClient
        } operation: {
            await CorpusSchema.isCompatible(version1)
        }
        #expect(isCompatible, "Schema should be compatible with itself")

        // Should not be compatible with different version
        let notCompatible1 = await withDependencies {
            $0.coverageCounters = mockClient
        } operation: {
            await CorpusSchema.isCompatible("v1-0")
        }
        let notCompatible2 = await withDependencies {
            $0.coverageCounters = mockClient
        } operation: {
            await CorpusSchema.isCompatible("v2-999")
        }
        #expect(!notCompatible1, "Different schema should not be compatible")
        #expect(!notCompatible2, "Different schema should not be compatible")
        #expect(snapshotSpy.callCount > 0, "Should have called snapshot")
    }

    @Test("CorpusSchema returns unknown when coverage unavailable")
    func testSchemaVersioningUnknown() async throws {
        // Use a mock client that returns nil (simulating coverage unavailable)
        let mockClient = CoverageCountersClient(
            snapshot: { nil },
            snapshotCoveredArrays: { nil },
            reset: {},
            isAvailable: { false },
            beginMeasurement: { nil },
            endMeasurement: { _ in },
            resetWithContext: { _ in },
            snapshotCoveredArraysWithContext: { _ in nil }
        )
        let version = await CorpusSchema.currentVersion(using: mockClient)
        #expect(version == "unknown", "Should return 'unknown' when coverage unavailable")
    }
}

// MARK: - Edge Case Tests

@Suite("Edge Cases")
struct EdgeCaseTests {

    @Test("Signature with many indices")
    func testManyIndices() async throws {
        let edges = Set(0..<1000)
        let sig = CoverageSignature(edges: edges)

        #expect(sig.executedCount == 1000)
        #expect(!sig.isEmpty)

        // Union with self should be idempotent
        let selfUnion = sig.union(with: sig)
        #expect(selfUnion == sig)
    }

    @Test("Corpus with complex input types")
    func testCorpusComplexTypes() async throws {
        let corpus = Corpus<[String]>(schemaVersion: "test")

        await corpus.add(
            input: ["a", "b", "c"],
            signature: CoverageSignature(edges: [0])
        )
        await corpus.add(
            input: [],
            signature: CoverageSignature(edges: [1])
        )
        await corpus.add(
            input: ["single"],
            signature: CoverageSignature(edges: [2])
        )

        let count = await corpus.count
        #expect(count == 3)

        // Test minimization
        let minimized = await corpus.minimized()
        #expect(minimized.count <= count)
    }

    @Test("CoverageSignature description")
    func testSignatureDescription() async throws {
        let sig = CoverageSignature(edges: [0, 1, 2])
        #expect(sig.description == "CoverageSignature(3 edges)")

        let empty = CoverageSignature(edges: [])
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
            // Use AlwaysInterestingCorpusRegistry to bypass coverage data requirements
            $0.corpusRegistry = AlwaysInterestingCorpusRegistry()
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
            try await fuzz(iterations: 20, duration: 5) { (input: Int) in
                _ = input > 0 ? "positive" : "non-positive"
            }
        }

        #expect(result.stats.totalInputs > 0)
        #expect(result.failures.isEmpty)
    }

    @Test("fuzz function accepts custom seeds")
    func testFuzzWithCustomSeeds() async throws {
        // Use AlwaysInterestingCorpusRegistry to bypass coverage data requirements
        let alwaysInterestingRegistry = AlwaysInterestingCorpusRegistry()

        let result = try await withDependencies {
            $0.corpusRegistry = alwaysInterestingRegistry
            $0.environment = EnvironmentClient(environment: { [:] })
        } operation: {
            // Use refuzzReplace to always start fresh (ignore any saved corpus)
            try await fuzz(seeds: ["custom1", "custom2", "custom3"], iterations: 50, duration: 5, corpusMode: .refuzzReplace) { (input: String) in
                // Just exercise the input - no actor involvement
                _ = input.count
            }
        }

        // Check that fuzz ran and processed seeds via stats
        // String.fuzz has 21 values + 3 custom = 24 seeds minimum
        #expect(result.stats.totalInputs >= 24, "Should process all seeds (got \(result.stats.totalInputs))")

        // Also check corpus has entries (since AlwaysInterestingCorpusRegistry adds everything)
        #expect(result.corpus.count > 0, "Corpus should have entries")
    }

}

// MARK: - SanCov Source Coverage API Tests

@Suite("SanCov Source Coverage API")
struct SanCovSourceCoverageAPITests {

    @Test("measureSanCovSourceCoverage captures source-level coverage")
    func testMeasureSanCovSourceCoverage() async {
        let coverage = await measureSanCovSourceCoverage {
            // Execute some code - use a local function to avoid optimization
            func compute() -> [Int] {
                [1, 2, 3].map { $0 * 2 }
            }
            _ = compute()
        }

        // Coverage should be captured if SanCov is available
        if let coverage = coverage {
            // getCoveredLocations filters out stdlib by default, so we only see test code edges.
            // Different compilers handle stdlib specialization instrumentation differently:
            // - Local/dev toolchain: Does NOT instrument specialized stdlib (e.g., Array.map)
            // - Xcode bundled toolchain: DOES instrument specialized stdlib
            // The isStdlibFunction() filter handles this transparently.
            //
            // Test code should always have exactly 5 edges regardless of toolchain:
            // 1 for outer closure, 2 for compute(), 2 for map closure
            #expect(
                coverage.coveredLocations.count == 5,
                "Expected exactly 5 test edges, got \(coverage.coveredLocations.count)"
            )
        }
    }

    @Test("measureSanCovSourceCoverage provides function coverage")
    func testMeasureSanCovSourceCoverageProvidesFunctions() async {
        let coverage = await measureSanCovSourceCoverage {
            _ = "test".uppercased()
        }

        // With SanCov we get function-level source mapping via dladdr
        if let coverage = coverage, SanCovCounters.pcsAvailable {
            #expect(!coverage.coveredFunctions.isEmpty, "Should have function names")
        }
    }

    @Test("measureSanCovSourceCoverage captures result value")
    func testMeasureSanCovSourceCoverageWithResult() async {
        var result: Int = 0
        let coverage = await measureSanCovSourceCoverage {
            result = 42
        }

        #expect(result == 42)
        if let coverage = coverage {
            #expect(coverage.coveredCount >= 0, "Coverage should be valid")
        }
    }
}
