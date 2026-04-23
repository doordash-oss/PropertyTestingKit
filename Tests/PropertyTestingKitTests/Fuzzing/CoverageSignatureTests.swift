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
        let signature = CoverageSignature(edges: Set<UInt32>([1, 3, 6]))
        #expect(signature.executedCount == 3)
        #expect(signature.executedIndices == Set<UInt32>([1, 3, 6]))
        #expect(signature.edges.contains(1))
        #expect(signature.edges.contains(3))
        #expect(signature.edges.contains(6))
        #expect(!signature.edges.contains(0))
    }

    @Test("Signature equality based on covered edges")
    func testSignatureEquality() {
        // Same edges should be equal
        let sig1 = CoverageSignature(edges: Set<UInt32>([1, 3, 5]))
        let sig2 = CoverageSignature(edges: Set<UInt32>([1, 3, 5]))
        #expect(sig1 == sig2)

        // Different edges should differ
        let sig3 = CoverageSignature(edges: Set<UInt32>([1, 3, 6]))
        #expect(sig1 != sig3)
    }

    @Test("Signature union combines coverage")
    func testSignatureUnion() {
        let sig1 = CoverageSignature(edges: Set<UInt32>([0, 1]))
        let sig2 = CoverageSignature(edges: Set<UInt32>([1, 2]))
        let union = sig1.union(with: sig2)

        #expect(union.executedIndices == Set<UInt32>([0, 1, 2]))
        #expect(union.edges.contains(0))
        #expect(union.edges.contains(1))
        #expect(union.edges.contains(2))
    }

    @Test("Signature detects unique coverage")
    func testUniqueCoverage() {
        let existing = CoverageSignature(edges: Set<UInt32>([0, 1]))
        let newSig = CoverageSignature(edges: Set<UInt32>([1, 2]))

        #expect(newSig.hasUniqueCoverage(comparedTo: existing))
        #expect(newSig.uniqueIndices(comparedTo: existing) == Set<UInt32>([2]))
    }

    @Test("Signature isEmpty")
    func testSignatureIsEmpty() {
        let empty = CoverageSignature(edges: Set<UInt32>())
        let nonEmpty = CoverageSignature(edges: Set<UInt32>([0]))

        #expect(empty.isEmpty)
        #expect(!nonEmpty.isEmpty)
    }

    @Test("Signature description")
    func testSignatureDescription() {
        let sig = CoverageSignature(edges: Set<UInt32>([1, 2, 3]))
        #expect(sig.description == "CoverageSignature(3 edges)")
    }

    @Test("Signature merge in place")
    func testSignatureMerge() {
        var sig1 = CoverageSignature(edges: Set<UInt32>([0, 1]))
        let sig2 = CoverageSignature(edges: Set<UInt32>([1, 2]))
        sig1.merge(with: sig2)

        #expect(sig1.edges == Set<UInt32>([0, 1, 2]))
    }

    @Test("Signature commonIndices")
    func testCommonIndices() {
        let sig1 = CoverageSignature(edges: Set<UInt32>([0, 1, 2]))
        let sig2 = CoverageSignature(edges: Set<UInt32>([1, 2, 3]))

        #expect(sig1.commonIndices(with: sig2) == Set<UInt32>([1, 2]))
    }

    @Test("Signature subtractIndices")
    func testSubtractIndices() {
        var set: Set<UInt32> = [0, 1, 2, 3, 4]
        let sig = CoverageSignature(edges: Set<UInt32>([1, 3]))
        sig.subtractIndices(from: &set)

        #expect(set == Set<UInt32>([0, 2, 4]))
    }

    @Test("Signature countIndicesIn")
    func testCountIndicesIn() {
        let sig = CoverageSignature(edges: Set<UInt32>([0, 1, 2, 3]))
        let subset: Set<UInt32> = [1, 3, 5, 7]

        #expect(sig.countIndicesIn(subset) == 2) // 1 and 3 are in both
    }
}
