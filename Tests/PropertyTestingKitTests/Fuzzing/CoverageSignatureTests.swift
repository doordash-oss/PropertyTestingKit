//
//  CoverageSignatureTests.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Testing
import Foundation
@testable import PropertyTestingKit

@Suite("CoverageSignature")
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

    @Test("Signature from SanCovCounters snapshot")
    func testSignatureFromSnapshot() {
        let counters = SanCovCounters(counters: [0, 1, 0, 128] as [UInt64])
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
