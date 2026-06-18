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

//  Sliding k-gram features of an ordered edge path.
//

/// Hashes an ordered edge path into sliding k-gram features — the `.pathTrie`
/// strategy's culling vocabulary.
///
/// A k-gram is a window of `k` consecutive edges; its hash is
/// position-dependent (A→B and B→A hash differently — order is exactly the
/// signal the path strategy exists to capture) and deterministic across
/// processes (corpus accounting must not change between runs, which rules out
/// the per-process-seeded `Hasher`).
public enum PathGrams {
    // FNV-1a constants; the multiply makes the fold non-commutative, which is
    // what carries position into the hash.
    private static let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
    private static let prime: UInt64 = 0x0000_0100_0000_01b3

    /// The hash of one gram (any ordered window of edges).
    public static func gramHash(_ window: some Sequence<UInt32>) -> UInt64 {
        var hash = offsetBasis
        for edge in window {
            hash = (hash ^ UInt64(edge)) &* prime
        }
        return hash
    }

    /// All sliding `gramLength`-gram hashes of `path`, in path order. A path
    /// shorter than one gram emits its whole-path hash instead — an accepted
    /// input must never have zero features (under feature ownership it would
    /// own nothing and be uncullable dead weight).
    public static func features(of path: [UInt32], gramLength: Int) -> [UInt64] {
        let k = max(1, gramLength)
        guard path.count >= k else {
            return [gramHash(path)]
        }
        var grams: [UInt64] = []
        grams.reserveCapacity(path.count - k + 1)
        for start in 0...(path.count - k) {
            grams.append(gramHash(path[start..<(start + k)]))
        }
        return grams
    }
}
