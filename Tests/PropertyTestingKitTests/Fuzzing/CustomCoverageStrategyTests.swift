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

//  Tests for user-defined coverage strategies built via the public CoverageStrategy API.
//

import Testing
import Foundation
// Intentionally a non-@testable import: this exercises the *public* custom-strategy surface
// (CoverageStrategy + SparseCoverage + Corpus) — no internal coverage plumbing.
import PropertyTestingKit

@Suite("Custom Coverage Strategy")
struct CustomCoverageStrategyTests {

    @Test("A custom strategy can add to the corpus via the public API")
    func customStrategyAddsToCorpus() async throws {
        // An "always interesting" strategy written entirely against public types:
        // pure judgement over the run's SparseCoverage — the engine records
        // interesting inputs; strategies never touch the corpus.
        let everything = CoverageStrategy { _ in true }

        let result = try await fuzzWithMaxIterations(
            maxIterations: 20,
            seeds: [1, 2, 3],
            persistence: .ephemeral,
            coverageStrategy: everything
        ) { (_: Int) in }

        #expect(!result.corpus.entries.isEmpty, "Custom strategy should have added corpus entries")
    }

    @Test("A custom strategy that rejects everything yields an empty corpus")
    func customStrategyCanReject() async throws {
        let nothing = CoverageStrategy { _ in false }

        let result = try await fuzzWithMaxIterations(
            maxIterations: 20,
            seeds: [1, 2, 3],
            persistence: .ephemeral,
            coverageStrategy: nothing
        ) { (_: Int) in }

        #expect(result.corpus.entries.isEmpty, "Rejecting strategy should add nothing to the corpus")
    }
}
