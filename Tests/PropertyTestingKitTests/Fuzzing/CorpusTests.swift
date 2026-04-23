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
    func testCorpusAddsInteresting() {
        let corpus = Corpus<Int>()
        var signatureHashes = Set<Int>()

        let sparse1 = SparseCoverage(indices: [0])
        let sparse2 = SparseCoverage(indices: [1])
        let sparse3 = SparseCoverage(indices: [0])  // Duplicate coverage

        let added1 = corpus.addIfInteresting(input: (1), sparse: sparse1, signatureHashes: &signatureHashes)
        let added2 = corpus.addIfInteresting(input: (2), sparse: sparse2, signatureHashes: &signatureHashes)
        let added3 = corpus.addIfInteresting(input: (3), sparse: sparse3, signatureHashes: &signatureHashes)

        #expect(added1)
        #expect(added2)
        #expect(!added3)  // Redundant

        #expect(corpus.count == 2)
    }

    @Test("Corpus minimization keeps essential entries")
    func testCorpusMinimization() {
        var corpus = Corpus<Int>()

        // Entry 1 covers indices 0, 1
        corpus.add(input: (1), sparse: SparseCoverage(indices: [0, 1]))
        // Entry 2 covers indices 1, 2
        corpus.add(input: (2), sparse: SparseCoverage(indices: [1, 2]))
        // Entry 3 covers indices 0, 2 (makes 1 and 2 redundant together)
        corpus.add(input: (3), sparse: SparseCoverage(indices: [0, 2]))

        let minimized = corpus.minimized()

        // Should need at most 2 entries to cover all 3 indices
        #expect(minimized.count <= 2)
        #expect(minimized.coveredIndices == Set([0, 1, 2]))
    }
}
