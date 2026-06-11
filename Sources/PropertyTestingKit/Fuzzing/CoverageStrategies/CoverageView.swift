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

//  The lazy coverage window a strategy decision judges.
//

/// The run's coverage as a strategy decision sees it: a lazy window onto the
/// engine's coverage map.
///
/// The sparse snapshot costs an O(covered-edges) allocation plus two copies,
/// and new coverage is rare — typically well under 1% of iterations — so
/// taking it eagerly would make the snapshot the dominant cost of every
/// rejected iteration. The view materializes the snapshot on first read and
/// reuses it, including for recording an interesting input in the corpus, so
/// decisions that never read coverage (like `.pathTrie`, whose oracle is its
/// own trie) judge allocation-free.
///
/// The view is only valid inside the `decide` call it is passed to; the
/// engine resets the underlying map between iterations.
public final class CoverageView {
    private enum State {
        case pending
        case unavailable
        case materialized(SparseCoverage)
    }

    private var state: State = .pending
    private let context: SanCovCounters.MeasurementContext
    private let client: CoverageCountersClient

    init(context: SanCovCounters.MeasurementContext, client: CoverageCountersClient) {
        self.context = context
        self.client = client
    }

    /// The run's covered edges. Empty when the snapshot is unavailable; such
    /// runs are never recorded in the corpus (the engine gates recording on
    /// `materialized()`), so a broken measurement cannot masquerade as a
    /// novel empty edge set.
    public var sparse: SparseCoverage {
        materialized() ?? SparseCoverage()
    }

    /// The edge indices the run covered (see `sparse`).
    public var indices: [UInt32] { sparse.indices }

    /// Materialize the snapshot on first call; `nil` when coverage is
    /// unavailable — distinct from the empty-`sparse` fallback the public
    /// accessors present, so storage can refuse broken measurements.
    func materialized() -> SparseCoverage? {
        switch state {
        case .materialized(let sparse):
            return sparse
        case .unavailable:
            return nil
        case .pending:
            guard let sparse = try? client.snapshotCoveredArraysWithContext(context) else {
                state = .unavailable
                return nil
            }
            state = .materialized(sparse)
            return sparse
        }
    }
}
