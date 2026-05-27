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
}
