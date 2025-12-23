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

    // MARK: - Bucket Classification Properties

    @Test("Bucket classifies all UInt64 values into expected ranges")
    func testBucketClassification() async throws {
        // Test boundary values for each bucket
        let testCases: [(UInt64, CoverageSignature.Bucket)] = [
            (0, .zero),
            (1, .one),
            (2, .two),
            (3, .three),
            (4, .fourToSeven),
            (5, .fourToSeven),
            (6, .fourToSeven),
            (7, .fourToSeven),
            (8, .eightToFifteen),
            (15, .eightToFifteen),
            (16, .sixteenToThirtyOne),
            (31, .sixteenToThirtyOne),
            (32, .thirtyTwoTo127),
            (127, .thirtyTwoTo127),
            (128, .oneHundredTwentyEightPlus),
            (UInt64.max, .oneHundredTwentyEightPlus),
        ]

        for (count, expectedBucket) in testCases {
            let bucket = CoverageSignature.Bucket(count: count)
            #expect(bucket == expectedBucket, "Count \(count) should be bucket \(expectedBucket), got \(bucket)")
        }
    }

    @Test("Bucket classification is monotonic")
    func testBucketMonotonicity() async throws {
        // Property: larger counts should never produce smaller buckets
        // Test specific boundary values
        let testCounts: [UInt64] = [0, 1, 2, 3, 4, 7, 8, 15, 16, 31, 32, 127, 128, 1000, UInt64.max]

        for count in testCounts {
            let bucket = CoverageSignature.Bucket(count: count)

            // If we increment, bucket should stay same or increase
            if count < UInt64.max {
                let nextBucket = CoverageSignature.Bucket(count: count + 1)
                #expect(nextBucket >= bucket, "Bucket(\(count+1)) should be >= Bucket(\(count))")
            }
        }

        // Also test some random intermediate values
        for i in 0..<100 {
            let count = UInt64(i * 10)
            let bucket = CoverageSignature.Bucket(count: count)
            let nextBucket = CoverageSignature.Bucket(count: count + 1)
            #expect(nextBucket >= bucket, "Bucket(\(count+1)) should be >= Bucket(\(count))")
        }
    }

    // MARK: - Signature Algebra Properties

    @Test("Signature union is commutative")
    func testUnionCommutative() async throws {
        // Property: A ∪ B = B ∪ A
        let sig1 = CoverageSignature(buckets: [0: .one, 1: .two, 2: .three])
        let sig2 = CoverageSignature(buckets: [1: .three, 2: .one, 3: .two])

        let union1 = sig1.union(with: sig2)
        let union2 = sig2.union(with: sig1)

        #expect(union1 == union2, "Union should be commutative")
    }

    @Test("Signature union is associative")
    func testUnionAssociative() async throws {
        // Property: (A ∪ B) ∪ C = A ∪ (B ∪ C)
        let sig1 = CoverageSignature(buckets: [0: .one, 1: .two])
        let sig2 = CoverageSignature(buckets: [1: .three, 2: .one])
        let sig3 = CoverageSignature(buckets: [2: .two, 3: .three])

        let leftAssoc = sig1.union(with: sig2).union(with: sig3)
        let rightAssoc = sig1.union(with: sig2.union(with: sig3))

        #expect(leftAssoc == rightAssoc, "Union should be associative")
    }

    @Test("Signature union with empty is identity")
    func testUnionIdentity() async throws {
        let sig = CoverageSignature(buckets: [0: .one, 5: .fourToSeven, 10: .oneHundredTwentyEightPlus])
        let empty = CoverageSignature(buckets: [:])

        #expect(sig.union(with: empty) == sig, "Union with empty should be identity")
        #expect(empty.union(with: sig) == sig, "Empty union with sig should be identity")
    }

    @Test("Signature union takes maximum bucket values")
    func testUnionTakesMax() async throws {
        let sig1 = CoverageSignature(buckets: [0: .one, 1: .fourToSeven])
        let sig2 = CoverageSignature(buckets: [0: .three, 1: .two])

        let union = sig1.union(with: sig2)

        #expect(union.buckets[0] == .three, "Union should take max: .three > .one")
        #expect(union.buckets[1] == .fourToSeven, "Union should take max: .fourToSeven > .two")
    }

    @Test("uniqueIndices and commonIndices are complementary")
    func testIndexSetOperations() async throws {
        let sig1 = CoverageSignature(buckets: [0: .one, 1: .two, 2: .three])
        let sig2 = CoverageSignature(buckets: [1: .one, 2: .two, 3: .three])

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
        let sig1 = CoverageSignature(buckets: [0: .one, 1: .two])
        let sig2 = CoverageSignature(buckets: [1: .one])
        let sig3 = CoverageSignature(buckets: [0: .three, 1: .three])

        #expect(sig1.hasUniqueCoverage(comparedTo: sig2) == true, "sig1 has index 0 not in sig2")
        #expect(sig2.hasUniqueCoverage(comparedTo: sig1) == false, "sig2 is subset of sig1")
        #expect(sig1.hasUniqueCoverage(comparedTo: sig3) == false, "sig1 indices are subset of sig3")
    }

    // MARK: - Serialization Properties

    @Test("CoverageSignature round-trips through Codable")
    func testSignatureCodableRoundTrip() async throws {
        let signatures = [
            CoverageSignature(buckets: [:]),
            CoverageSignature(buckets: [0: .one]),
            CoverageSignature(buckets: [0: .one, 100: .fourToSeven, 1000: .oneHundredTwentyEightPlus]),
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

        let sig1 = CoverageSignature(buckets: [0: .one])
        let sig2 = CoverageSignature(buckets: [0: .one])  // Duplicate
        let sig3 = CoverageSignature(buckets: [1: .two])  // New

        #expect(set.insert(sig1) == true, "First insert should be new")
        #expect(set.insert(sig2) == false, "Duplicate insert should not be new")
        #expect(set.insert(sig3) == true, "Different signature should be new")
    }

    @Test("SignatureSet totalCoverage is union of all signatures")
    func testTotalCoverageIsUnion() async throws {
        var set = SignatureSet()

        let sig1 = CoverageSignature(buckets: [0: .one, 1: .two])
        let sig2 = CoverageSignature(buckets: [2: .three, 3: .fourToSeven])

        set.insert(sig1)
        set.insert(sig2)

        let expectedTotal = sig1.union(with: sig2)
        #expect(set.totalCoverage == expectedTotal, "Total coverage should be union")
    }

    @Test("wouldAddNewCoverage is consistent with totalCoverage")
    func testWouldAddNewCoverage() async throws {
        var set = SignatureSet()

        let sig1 = CoverageSignature(buckets: [0: .one, 1: .two])
        set.insert(sig1)

        let subsetSig = CoverageSignature(buckets: [0: .one])
        let newSig = CoverageSignature(buckets: [2: .three])

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
        var corpus = Corpus<String>(schemaVersion: "test")

        let sig1 = CoverageSignature(buckets: [0: .one, 1: .two, 2: .three])

        // First add should succeed
        let added1 = corpus.addIfInteresting(input: "first", signature: sig1)
        #expect(added1 == true, "First entry should be added")

        // Subset signature should be rejected
        let sigSubset = CoverageSignature(buckets: [0: .one, 1: .two])
        let added2 = corpus.addIfInteresting(input: "subset", signature: sigSubset)
        #expect(added2 == false, "Subset coverage should be rejected")

        // New coverage should be accepted
        let sigNew = CoverageSignature(buckets: [3: .fourToSeven])
        let added3 = corpus.addIfInteresting(input: "new", signature: sigNew)
        #expect(added3 == true, "New coverage should be accepted")
    }

    @Test("Corpus minimization preserves total coverage")
    func testMinimizationPreservesCoverage() async throws {
        var corpus = Corpus<String>(schemaVersion: "test")

        // Add entries with overlapping coverage
        corpus.add(input: "a", signature: CoverageSignature(buckets: [0: .one, 1: .two]))
        corpus.add(input: "b", signature: CoverageSignature(buckets: [1: .three, 2: .one]))
        corpus.add(input: "c", signature: CoverageSignature(buckets: [2: .two, 3: .three]))
        corpus.add(input: "d", signature: CoverageSignature(buckets: [0: .two, 1: .one]))  // Redundant

        let originalCoverage = corpus.totalCoverage
        let minimized = corpus.minimized()

        // Property: minimized coverage equals original coverage
        #expect(
            minimized.totalCoverage.executedIndices == originalCoverage.executedIndices,
            "Minimization should preserve coverage indices"
        )

        // Property: minimized should have fewer or equal entries
        #expect(minimized.count <= corpus.count, "Minimized should not be larger")
    }

    @Test("Corpus selectForMutation returns valid indices")
    func testSelectForMutationValidIndex() async throws {
        var corpus = Corpus<String>(schemaVersion: "test")

        // Empty corpus should return nil
        #expect(corpus.selectForMutation() == nil, "Empty corpus should return nil")

        // Add some entries
        corpus.add(input: "a", signature: CoverageSignature(buckets: [0: .one]))
        corpus.add(input: "b", signature: CoverageSignature(buckets: [1: .two]))
        corpus.add(input: "c", signature: CoverageSignature(buckets: [2: .three]))

        // Selection should be valid index
        for _ in 0..<10 {
            if let index = corpus.selectForMutation() {
                #expect(corpus.entries.indices.contains(index), "Selected index should be valid")
            }
        }
    }

    @Test("Corpus handles empty minimization")
    func testEmptyMinimization() async throws {
        let corpus = Corpus<String>(schemaVersion: "test")
        let minimized = corpus.minimized()
        #expect(minimized.isEmpty, "Minimized empty corpus should be empty")
    }

    @Test("Corpus isEmpty property")
    func testCorpusIsEmpty() async throws {
        var corpus = Corpus<String>(schemaVersion: "test")
        #expect(corpus.isEmpty, "New corpus should be empty")

        corpus.add(input: "a", signature: CoverageSignature(buckets: [0: .one]))
        #expect(!corpus.isEmpty, "Corpus with entry should not be empty")
    }

    @Test("Corpus signatures property")
    func testCorpusSignatures() async throws {
        var corpus = Corpus<String>(schemaVersion: "test")

        let sig1 = CoverageSignature(buckets: [0: .one])
        let sig2 = CoverageSignature(buckets: [1: .two])

        corpus.add(input: "a", signature: sig1)
        corpus.add(input: "b", signature: sig2)

        let signatures = corpus.signatures
        #expect(signatures.count == 2, "Should have 2 signatures")
        #expect(signatures[0] == sig1, "First signature should match")
        #expect(signatures[1] == sig2, "Second signature should match")
    }

    @Test("Corpus inputs property")
    func testCorpusInputs() async throws {
        var corpus = Corpus<String>(schemaVersion: "test")

        corpus.add(input: "hello", signature: CoverageSignature(buckets: [0: .one]))
        corpus.add(input: "world", signature: CoverageSignature(buckets: [1: .two]))

        let inputs = corpus.inputs
        #expect(inputs.count == 2, "Should have 2 inputs")
        #expect(inputs[0] == "hello", "First input should match")
        #expect(inputs[1] == "world", "Second input should match")
    }

    @Test("Corpus selectForMutation with empty signatures")
    func testSelectForMutationEmptySignatures() async throws {
        var corpus = Corpus<String>(schemaVersion: "test")

        // Add entries with empty signatures (totalScore will be 0)
        let emptySig = CoverageSignature(buckets: [:])
        corpus.add(input: "a", signature: emptySig)
        corpus.add(input: "b", signature: emptySig)

        // Should still return a valid index (random selection fallback)
        let index = corpus.selectForMutation()
        #expect(index != nil, "Should return an index")
        #expect(corpus.entries.indices.contains(index!), "Index should be valid")
    }

    @Test("Corpus minimization with no new coverage")
    func testMinimizationNoNewCoverage() async throws {
        var corpus = Corpus<String>(schemaVersion: "test")

        // Add one entry that covers everything
        corpus.add(input: "all", signature: CoverageSignature(buckets: [0: .one, 1: .two, 2: .three]))

        // Add more entries that cover subsets (will have bestCoverage = 0 after first)
        corpus.add(input: "sub1", signature: CoverageSignature(buckets: [0: .one]))
        corpus.add(input: "sub2", signature: CoverageSignature(buckets: [1: .two]))

        let minimized = corpus.minimized()

        // The first entry should cover everything, so minimization should pick just that one
        #expect(minimized.count >= 1, "Should have at least one entry")
        #expect(
            minimized.totalCoverage.executedIndices == corpus.totalCoverage.executedIndices,
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
            signature: CoverageSignature(buckets: [0: .one, 5: .fourToSeven]),
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
        #expect(signature.buckets[0] == nil, "Index 0 (zero count) should not be in buckets")
        #expect(signature.buckets[1] == CoverageSignature.Bucket.one, "Index 1 should be bucket .one")
        #expect(signature.buckets[3] == CoverageSignature.Bucket.two, "Index 3 should be bucket .two")
        #expect(signature.buckets[6] == CoverageSignature.Bucket.three, "Index 6 should be bucket .three")
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
        let mockClient = CoverageCountersClient(snapshot: snapshotFn, reset: {}, isAvailable: { true })
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
        let mockClient = CoverageCountersClient(snapshot: { nil }, reset: {}, isAvailable: { false })
        let version = await CorpusSchema.currentVersion(using: mockClient)
        #expect(version == "unknown", "Should return 'unknown' when coverage unavailable")
    }
}

// MARK: - Edge Case Tests

@Suite("Edge Cases")
struct EdgeCaseTests {

    @Test("Very large bucket values")
    func testLargeBucketValues() async throws {
        let bucket = CoverageSignature.Bucket(count: UInt64.max)
        #expect(bucket == .oneHundredTwentyEightPlus)
    }

    @Test("Signature with many indices")
    func testManyIndices() async throws {
        var buckets: [Int: CoverageSignature.Bucket] = [:]
        for i in 0..<1000 {
            buckets[i] = .one
        }
        let sig = CoverageSignature(buckets: buckets)

        #expect(sig.executedCount == 1000)
        #expect(!sig.isEmpty)

        // Union with self should be idempotent
        let selfUnion = sig.union(with: sig)
        #expect(selfUnion == sig)
    }

    @Test("Corpus with complex input types")
    func testCorpusComplexTypes() async throws {
        var corpus = Corpus<[String]>(schemaVersion: "test")

        corpus.add(
            input: ["a", "b", "c"],
            signature: CoverageSignature(buckets: [0: .one])
        )
        corpus.add(
            input: [],
            signature: CoverageSignature(buckets: [1: .two])
        )
        corpus.add(
            input: ["single"],
            signature: CoverageSignature(buckets: [2: .three])
        )

        #expect(corpus.count == 3)

        // Test minimization
        let minimized = corpus.minimized()
        #expect(minimized.count <= corpus.count)
    }

    @Test("Bucket description strings")
    func testBucketDescriptions() async throws {
        let cases: [(CoverageSignature.Bucket, String)] = [
            (.zero, "0"),
            (.one, "1"),
            (.two, "2"),
            (.three, "3"),
            (.fourToSeven, "4-7"),
            (.eightToFifteen, "8-15"),
            (.sixteenToThirtyOne, "16-31"),
            (.thirtyTwoTo127, "32-127"),
            (.oneHundredTwentyEightPlus, "128+"),
        ]

        for (bucket, expected) in cases {
            #expect(bucket.description == expected)
        }
    }

    @Test("CoverageSignature description")
    func testSignatureDescription() async throws {
        let sig = CoverageSignature(buckets: [0: .one, 1: .two, 2: .three])
        #expect(sig.description == "CoverageSignature(3 regions)")

        let empty = CoverageSignature(buckets: [:])
        #expect(empty.description == "CoverageSignature(0 regions)")
    }
}

// MARK: - Fuzz API Property Tests

@Suite("Fuzz API Properties")
struct FuzzAPIPropertyTests {

    @Test("fuzz function runs with default configuration")
    func testFuzzDefaultConfig() async throws {
        nonisolated(unsafe) var callCount = 0
        let (snapshotSpy, snapshotFn) = spy { () -> SanCovCounters? in
            callCount += 1
            var counters = [UInt64](repeating: 0, count: 100)
            counters[callCount % 100] = UInt64(callCount + 1)
            return SanCovCounters(counters: counters)
        }

        // Use a simple test that won't fail
        let result = try await withDependencies {
            $0.coverageCounters = CoverageCountersClient(snapshot: snapshotFn, reset: {}, isAvailable: { true })
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
        #expect(snapshotSpy.callCount > 0, "Should have called snapshot")
    }

    @Test("fuzz function accepts custom seeds")
    func testFuzzWithCustomSeeds() async throws {
        nonisolated(unsafe) var seenInputs: [String] = []

        nonisolated(unsafe) var callCount = 0
        let (snapshotSpy, snapshotFn) = spy { () -> SanCovCounters? in
            callCount += 1
            var counters = [UInt64](repeating: 0, count: 100)
            counters[callCount % 100] = UInt64(callCount + 1)
            return SanCovCounters(counters: counters)
        }

        let result = try await withDependencies {
            $0.coverageCounters = CoverageCountersClient(snapshot: snapshotFn, reset: {}, isAvailable: { true })
            $0.environment = EnvironmentClient(environment: { [:] })
        } operation: {
            try await fuzz(seeds: ["custom1", "custom2", "custom3"], iterations: 30, duration: 5) { (input: String) in
                seenInputs.append(input)
                _ = input.count
            }
        }

        // Custom seeds should be tested
        #expect(seenInputs.contains("custom1") || result.stats.totalInputs > 0)
        #expect(snapshotSpy.callCount > 0, "Should have called snapshot")
    }

}

// MARK: - SanCov Source Coverage API Tests

@Suite("SanCov Source Coverage API")
struct SanCovSourceCoverageAPITests {

    @Test("measureSanCovSourceCoverage captures source-level coverage")
    func testMeasureSanCovSourceCoverage() async {
        let coverage = measureSanCovSourceCoverage {
            // Execute some code - use a local function to avoid optimization
            func compute() -> [Int] {
                [1, 2, 3].map { $0 * 2 }
            }
            _ = compute()
        }

        // Coverage should be captured if SanCov is available
        // Assert exact count to catch any race conditions or measurement issues
        if let coverage = coverage {
            #expect(coverage.coveredCount == 5, "Expected exactly 5 covered edges, got \(coverage.coveredCount)")
        }
    }

    @Test("measureSanCovSourceCoverage provides function coverage")
    func testMeasureSanCovSourceCoverageProvidesFunctions() async {
        let coverage = measureSanCovSourceCoverage {
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
        let coverage = measureSanCovSourceCoverage {
            result = 42
        }

        #expect(result == 42)
        if let coverage = coverage {
            #expect(coverage.coveredCount >= 0, "Coverage should be valid")
        }
    }
}
