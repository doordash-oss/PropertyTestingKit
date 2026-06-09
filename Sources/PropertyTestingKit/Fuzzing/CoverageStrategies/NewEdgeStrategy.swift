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

//  New edge strategy: any previously-unseen edge is interesting (AFL/libFuzzer).
//

extension CoverageStrategy {
    /// New edge strategy: bitmap merge — any previously-unseen edge is interesting (AFL/libFuzzer).
    public static var newEdge: CoverageStrategy<repeat each Input> {
        CoverageStrategy(builtin: .newEdge, makeEngine: { makeNewEdgeEngine() })
    }
}

/// New edge strategy: any previously-unseen edge (per the corpus's global
/// seen-edges bitmap) is interesting. Aligns with AFL/libFuzzer model.
private func makeNewEdgeEngine<each Input: Codable & Sendable>(
) -> CoverageEngine<repeat each Input> {
    CoverageEngine { sparse, corpus, input, scheduleBytes in
        guard corpus.mergeCoverage(sparse) else {
            return false
        }

        // mergeCoverage already merged the bitmap — record without re-merging.
        corpus.addEntry(input: input, scheduleBytes: scheduleBytes, sparse: sparse)
        return true
    }
}
