//
//  CoverageSignatureTests.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Testing
import Foundation
@testable import PropertyTestingKit

@Suite("CoverageSignature", .serialized)
struct CoverageSignatureTests {

    @Test("Bucket categorizes counts correctly")
    func testBucketCategorization() {
        #expect(CoverageSignature.Bucket(count: 0) == .zero)
        #expect(CoverageSignature.Bucket(count: 1) == .one)
        #expect(CoverageSignature.Bucket(count: 2) == .two)
        #expect(CoverageSignature.Bucket(count: 3) == .three)
        #expect(CoverageSignature.Bucket(count: 4) == .fourToSeven)
        #expect(CoverageSignature.Bucket(count: 7) == .fourToSeven)
        #expect(CoverageSignature.Bucket(count: 8) == .eightToFifteen)
        #expect(CoverageSignature.Bucket(count: 15) == .eightToFifteen)
        #expect(CoverageSignature.Bucket(count: 16) == .sixteenToThirtyOne)
        #expect(CoverageSignature.Bucket(count: 31) == .sixteenToThirtyOne)
        #expect(CoverageSignature.Bucket(count: 32) == .thirtyTwoTo127)
        #expect(CoverageSignature.Bucket(count: 127) == .thirtyTwoTo127)
        #expect(CoverageSignature.Bucket(count: 128) == .oneHundredTwentyEightPlus)
        #expect(CoverageSignature.Bucket(count: 1000) == .oneHundredTwentyEightPlus)
    }

    @Test("Signature from counters excludes zeros")
    func testSignatureFromCounters() {
        let signature = CoverageSignature(counters: [0, 1, 0, 5, 0, 0, 100])
        #expect(signature.executedCount == 3)
        #expect(signature.executedIndices == Set([1, 3, 6]))
        #expect(signature.buckets[1] == .one)
        #expect(signature.buckets[3] == .fourToSeven)
        #expect(signature.buckets[6] == .thirtyTwoTo127)
    }

    @Test("Signature equality based on buckets")
    func testSignatureEquality() {
        // Same bucket should be equal
        let sig1 = CoverageSignature(counters: [0, 5, 0])
        let sig2 = CoverageSignature(counters: [0, 6, 0])
        #expect(sig1 == sig2)  // Both 5 and 6 are in bucket 4-7

        // Different buckets should differ
        let sig3 = CoverageSignature(counters: [0, 8, 0])
        #expect(sig1 != sig3)  // 5 is bucket 4-7, 8 is bucket 8-15
    }

    @Test("Signature union combines coverage")
    func testSignatureUnion() {
        let sig1 = CoverageSignature(buckets: [0: .one, 1: .two])
        let sig2 = CoverageSignature(buckets: [1: .three, 2: .one])
        let union = sig1.union(with: sig2)

        #expect(union.executedIndices == Set([0, 1, 2]))
        #expect(union.buckets[0] == .one)
        #expect(union.buckets[1] == .three)  // Max of .two and .three
        #expect(union.buckets[2] == .one)
    }

    @Test("Signature detects unique coverage")
    func testUniqueCoverage() {
        let existing = CoverageSignature(buckets: [0: .one, 1: .one])
        let newSig = CoverageSignature(buckets: [1: .one, 2: .one])

        #expect(newSig.hasUniqueCoverage(comparedTo: existing))
        #expect(newSig.uniqueIndices(comparedTo: existing) == Set([2]))
    }

    @Test("Signature from CounterDiff")
    func testSignatureFromDiff() {
        let before = CoverageCounters(counters: [0, 5, 10])
        let after = CoverageCounters(counters: [3, 5, 15])
        let diff = after.difference(from: before)
        let signature = CoverageSignature(diff: diff)

        // Index 0: 0 -> 3 = delta 3
        // Index 1: 5 -> 5 = delta 0 (no change)
        // Index 2: 10 -> 15 = delta 5
        #expect(signature.buckets[0] == .three)
        #expect(signature.buckets[1] == nil)
        #expect(signature.buckets[2] == .fourToSeven)
    }

    @Test("Signature from CounterDiff with different array sizes")
    func testSignatureFromDiffDifferentSizes() {
        // Before has more counters
        let before = CoverageCounters(counters: [10, 20, 30])
        let after = CoverageCounters(counters: [15])
        let diff = after.difference(from: before)
        let signature = CoverageSignature(diff: diff)

        // Index 0: 10 -> 15 = delta 5
        // Index 1: 20 -> 0 (missing) = delta would be negative, clamped to 0
        // Index 2: 30 -> 0 (missing) = delta would be negative, clamped to 0
        #expect(signature.buckets[0] == .fourToSeven)
        #expect(signature.buckets[1] == nil)  // No coverage (delta 0)
        #expect(signature.buckets[2] == nil)  // No coverage (delta 0)
    }

    @Test("Signature from CounterDiff when after is larger")
    func testSignatureFromDiffAfterLarger() {
        let before = CoverageCounters(counters: [5])
        let after = CoverageCounters(counters: [10, 20, 30])
        let diff = after.difference(from: before)
        let signature = CoverageSignature(diff: diff)

        // Index 0: 5 -> 10 = delta 5
        // Index 1: 0 -> 20 = delta 20
        // Index 2: 0 -> 30 = delta 30
        #expect(signature.buckets[0] == .fourToSeven)
        #expect(signature.buckets[1] == .sixteenToThirtyOne)
        #expect(signature.buckets[2] == .sixteenToThirtyOne)
    }

    @Test("Signature from CoverageCounters snapshot")
    func testSignatureFromSnapshot() {
        let counters = CoverageCounters(counters: [0, 1, 0, 128])
        let signature = CoverageSignature(snapshot: counters)

        #expect(signature.executedCount == 2)
        #expect(signature.buckets[1] == .one)
        #expect(signature.buckets[3] == .oneHundredTwentyEightPlus)
    }

    @Test("Signature isEmpty")
    func testSignatureIsEmpty() {
        let empty = CoverageSignature(buckets: [:])
        let nonEmpty = CoverageSignature(buckets: [0: .one])

        #expect(empty.isEmpty)
        #expect(!nonEmpty.isEmpty)
    }

    @Test("Bucket description")
    func testBucketDescription() {
        #expect(CoverageSignature.Bucket.zero.description == "0")
        #expect(CoverageSignature.Bucket.one.description == "1")
        #expect(CoverageSignature.Bucket.two.description == "2")
        #expect(CoverageSignature.Bucket.three.description == "3")
        #expect(CoverageSignature.Bucket.fourToSeven.description == "4-7")
        #expect(CoverageSignature.Bucket.eightToFifteen.description == "8-15")
        #expect(CoverageSignature.Bucket.sixteenToThirtyOne.description == "16-31")
        #expect(CoverageSignature.Bucket.thirtyTwoTo127.description == "32-127")
        #expect(CoverageSignature.Bucket.oneHundredTwentyEightPlus.description == "128+")
    }

    @Test("SignatureSet count and totalCoveredIndices")
    func testSignatureSetProperties() {
        var set = SignatureSet()
        #expect(set.count == 0)
        #expect(set.totalCoveredIndices == 0)

        set.insert(CoverageSignature(buckets: [0: .one, 1: .two]))
        #expect(set.count == 1)
        #expect(set.totalCoveredIndices == 2)

        set.insert(CoverageSignature(buckets: [2: .three]))
        #expect(set.count == 2)
        #expect(set.totalCoveredIndices == 3)
    }
}
