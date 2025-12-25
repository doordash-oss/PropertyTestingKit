//
//  CorpusTests.swift
//  Copyright © 2025 DoorDash. All rights reserved.
//

import Testing
import Foundation
import Dependencies
import FunctionSpy
@testable import PropertyTestingKit

@Suite("Corpus")
struct CorpusTests {

    @Test("Corpus adds interesting entries")
    func testCorpusAddsInteresting() async {
        let corpus = Corpus<Int>(schemaVersion: "test")

        let sig1 = CoverageSignature(buckets: [0: .one])
        let sig2 = CoverageSignature(buckets: [1: .one])
        let sig3 = CoverageSignature(buckets: [0: .one])  // Duplicate coverage

        let added1 = await corpus.addIfInteresting(input: 1, signature: sig1)
        let added2 = await corpus.addIfInteresting(input: 2, signature: sig2)
        let added3 = await corpus.addIfInteresting(input: 3, signature: sig3)

        #expect(added1)
        #expect(added2)
        #expect(!added3)  // Redundant

        let count = await corpus.count
        #expect(count == 2)
    }

    @Test("Corpus minimization keeps essential entries")
    func testCorpusMinimization() async {
        let corpus = Corpus<Int>(schemaVersion: "test")

        // Entry 1 covers indices 0, 1
        await corpus.add(input: 1, signature: CoverageSignature(buckets: [0: .one, 1: .one]))
        // Entry 2 covers indices 1, 2
        await corpus.add(input: 2, signature: CoverageSignature(buckets: [1: .one, 2: .one]))
        // Entry 3 covers indices 0, 2 (makes 1 and 2 redundant together)
        await corpus.add(input: 3, signature: CoverageSignature(buckets: [0: .one, 2: .one]))

        let minimized = await corpus.minimized()

        // Should need at most 2 entries to cover all 3 indices
        #expect(minimized.count <= 2)
        #expect(minimized.totalCoverage.executedIndices == Set([0, 1, 2]))
    }
}
