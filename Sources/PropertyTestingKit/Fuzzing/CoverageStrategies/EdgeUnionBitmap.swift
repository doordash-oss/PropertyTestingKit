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

//  The edge-coverage UNION oracle: "has any run this engine has seen ever hit
//  this edge?". Every coverage strategy maintains one (it is never weaker than
//  .newEdge). It was a Set<UInt32>, but SanCov edge indices are dense and bounded
//  by the guard count, so the per-iteration `seenEdges.insert(edge).inserted`
//  loop over every covered edge paid Set hashing + bucket work on the hottest
//  path in the whole fuzzer — ~7% of the process across every strategy
//  (scheduler-lab Finding 41m). A packed bit array gives the same `.inserted`
//  answer in O(1) with no hashing and, after warm-up, no allocation.

/// A test-and-set bitmap over SanCov edge indices. Drop-in for the union half of
/// `Set<UInt32>`: `insert(_:)` returns whether the edge was newly covered, the
/// same contract as `Set.insert(_:).inserted`.
struct EdgeUnionBitmap {
    /// Packed bits, 64 edges per word. Grown lazily to cover the highest edge
    /// index seen; after the first runs touch the full edge set it never grows
    /// again, so steady-state inserts allocate nothing.
    private var words: [UInt64] = []

    init() {}

    /// Mark `edge` covered. Returns `true` iff it was NOT already covered.
    @inline(__always)
    mutating func insert(_ edge: UInt32) -> Bool {
        let word = Int(edge >> 6)
        let bit = UInt64(1) << (UInt64(edge) & 63)
        if word >= words.count {
            words.append(contentsOf: repeatElement(0, count: word - words.count + 1))
        }
        if words[word] & bit != 0 { return false }
        words[word] |= bit
        return true
    }

    /// Whether `edge` has been covered (membership without mutating).
    @inline(__always)
    func contains(_ edge: UInt32) -> Bool {
        let word = Int(edge >> 6)
        guard word < words.count else { return false }
        return words[word] & (UInt64(1) << (UInt64(edge) & 63)) != 0
    }

    /// Number of distinct edges covered.
    var count: Int { words.reduce(0) { $0 + $1.nonzeroBitCount } }

    var isEmpty: Bool { words.allSatisfy { $0 == 0 } }
}
