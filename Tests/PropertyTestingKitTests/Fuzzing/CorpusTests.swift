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
    func testCorpusAppendsEntries() {
        // The corpus no longer judges interestingness or dedups — membership is
        // the scheduler's decision, and the corpus just stores what it is given.
        // (Cross-engine input-identity dedup lives in `mergeCorpusSnapshots`.)
        let corpus = Corpus<Int>()

        corpus.add(input: 1)
        corpus.add(input: 2)
        corpus.add(input: 3)

        #expect(corpus.count == 3)
        #expect(corpus.inputs == [1, 2, 3])
    }
}
