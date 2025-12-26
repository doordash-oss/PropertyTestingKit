//
//  CoverageSignatureTests.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Testing
import Foundation
@testable import PropertyTestingKit

@Suite("CoverageSignature")
struct CoverageSignatureTests {

    @Test("Signature from counters excludes zeros")
    func testSignatureFromCounters() {
        let signature = CoverageSignature(counters: [0, 1, 0, 5, 0, 0, 100])
        #expect(signature.executedCount == 3)
        #expect(signature.executedIndices == Set([1, 3, 6]))
        #expect(signature.edges.contains(1))
        #expect(signature.edges.contains(3))
        #expect(signature.edges.contains(6))
        #expect(!signature.edges.contains(0))
    }

    @Test("Signature equality based on covered edges")
    func testSignatureEquality() {
        // Same edges should be equal
        let sig1 = CoverageSignature(edges: [1, 3, 5])
        let sig2 = CoverageSignature(edges: [1, 3, 5])
        #expect(sig1 == sig2)

        // Different edges should differ
        let sig3 = CoverageSignature(edges: [1, 3, 6])
        #expect(sig1 != sig3)
    }

    @Test("Signature union combines coverage")
    func testSignatureUnion() {
        let sig1 = CoverageSignature(edges: [0, 1])
        let sig2 = CoverageSignature(edges: [1, 2])
        let union = sig1.union(with: sig2)

        #expect(union.executedIndices == Set([0, 1, 2]))
        #expect(union.edges.contains(0))
        #expect(union.edges.contains(1))
        #expect(union.edges.contains(2))
    }

    @Test("Signature detects unique coverage")
    func testUniqueCoverage() {
        let existing = CoverageSignature(edges: [0, 1])
        let newSig = CoverageSignature(edges: [1, 2])

        #expect(newSig.hasUniqueCoverage(comparedTo: existing))
        #expect(newSig.uniqueIndices(comparedTo: existing) == Set([2]))
    }

    @Test("Signature from SanCovCounters snapshot")
    func testSignatureFromSnapshot() {
        let counters = SanCovCounters(counters: [0, 1, 0, 128] as [UInt64])
        let signature = CoverageSignature(snapshot: counters)

        #expect(signature.executedCount == 2)
        #expect(signature.edges.contains(1))
        #expect(signature.edges.contains(3))
        #expect(!signature.edges.contains(0))
        #expect(!signature.edges.contains(2))
    }

    @Test("Signature isEmpty")
    func testSignatureIsEmpty() {
        let empty = CoverageSignature(edges: [])
        let nonEmpty = CoverageSignature(edges: [0])

        #expect(empty.isEmpty)
        #expect(!nonEmpty.isEmpty)
    }

    @Test("Signature description")
    func testSignatureDescription() {
        let sig = CoverageSignature(edges: [1, 2, 3])
        #expect(sig.description == "CoverageSignature(3 edges)")
    }

    @Test("SignatureSet count and totalCoveredIndices")
    func testSignatureSetProperties() {
        var set = SignatureSet()
        #expect(set.count == 0)
        #expect(set.totalCoveredIndices == 0)

        set.insert(CoverageSignature(edges: [0, 1]))
        #expect(set.count == 1)
        #expect(set.totalCoveredIndices == 2)

        set.insert(CoverageSignature(edges: [2]))
        #expect(set.count == 2)
        #expect(set.totalCoveredIndices == 3)
    }

    @Test("Signature merge in place")
    func testSignatureMerge() {
        var sig1 = CoverageSignature(edges: [0, 1])
        let sig2 = CoverageSignature(edges: [1, 2])
        sig1.merge(with: sig2)

        #expect(sig1.edges == Set([0, 1, 2]))
    }

    @Test("Signature commonIndices")
    func testCommonIndices() {
        let sig1 = CoverageSignature(edges: [0, 1, 2])
        let sig2 = CoverageSignature(edges: [1, 2, 3])

        #expect(sig1.commonIndices(with: sig2) == Set([1, 2]))
    }

    @Test("Signature subtractIndices")
    func testSubtractIndices() {
        var set: Set<Int> = [0, 1, 2, 3, 4]
        let sig = CoverageSignature(edges: [1, 3])
        sig.subtractIndices(from: &set)

        #expect(set == Set([0, 2, 4]))
    }

    @Test("Signature countIndicesIn")
    func testCountIndicesIn() {
        let sig = CoverageSignature(edges: [0, 1, 2, 3])
        let subset: Set<Int> = [1, 3, 5, 7]

        #expect(sig.countIndicesIn(subset) == 2) // 1 and 3 are in both
    }
}
