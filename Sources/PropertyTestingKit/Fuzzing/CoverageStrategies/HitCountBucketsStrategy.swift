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

//  Hit-count buckets strategy: a new per-edge hit-count bucket is interesting
//  (AFL++/libFuzzer counter features).
//

extension CoverageStrategy {
    /// Hit-count buckets strategy: an input is interesting iff some edge's
    /// per-run hit count lands in a bucket this engine hasn't seen for that
    /// edge (AFL++/libFuzzer counter features).
    ///
    /// Counts are classed into the AFL++ power-of-two buckets — 1, 2, 3, 4–7,
    /// 8–15, 16–31, 32–127, 128+ — so a loop running a meaningfully different
    /// number of times is novel, while count jitter inside a bucket is not.
    /// Strictly finer than `.newEdge`: a first-ever edge is always a new
    /// bucket, and a known edge re-hit a bucket-crossing number of times is
    /// novel too.
    public static var hitCountBuckets: CoverageStrategy {
        CoverageStrategy(makeEngine: { makeHitCountBucketsEngine() })
    }
}

/// The AFL++ bucket of a hit count, as a single bit so an edge's seen buckets
/// pack into a UInt8 bitmask. Only the observed bucket is marked — seeing
/// count 4 does not imply counts 1–3 were seen.
private func bucketBit(forHitCount count: UInt32) -> UInt8 {
    switch count {
    case 1: 1 << 0
    case 2: 1 << 1
    case 3: 1 << 2
    case 4...7: 1 << 3
    case 8...15: 1 << 4
    case 16...31: 1 << 5
    case 32...127: 1 << 6
    default: 1 << 7
    }
}

/// Hit-count buckets engine: `onEdge` is the measurement half (per-run hit
/// counts — the coverage map only records *covered*, so the strategy counts
/// for itself), `decide` the judgement half (bucket each count, interesting
/// iff any (edge, bucket) pair is new to this engine). The novelty oracle is
/// the STRATEGY's own per-engine state — the corpus stores results, it
/// doesn't judge them.
private func makeHitCountBucketsEngine() -> CoverageEngine {
    // One lock for both halves is safe: onEdge, onReset, and decide all run
    // under the per-thread observer gate, so edges their own code fires are
    // recorded but never dispatched back into onEdge.
    struct BucketState {
        /// This iteration's per-edge hit counts (cleared on reset).
        var hitCounts: [UInt32: UInt32] = [:]
        /// Engine-lifetime per-edge bitmask of observed buckets.
        var seenBuckets: [UInt32: UInt8] = [:]
        /// The last accepted run's (edge, bucket) features — the strategy's
        /// culling vocabulary, stashed at decide time because the counts it
        /// derives from are cleared before decide returns.
        var lastFeatures: [UInt64] = []
    }
    let state = SyncBox<BucketState>(BucketState())

    return CoverageEngine(
        onEdge: { edge, _ in
            state.update { $0.hitCounts[edge, default: 0] += 1 }
        },
        onReset: {
            state.update { $0.hitCounts.removeAll(keepingCapacity: true) }
        },
        features: { state.value.lastFeatures }
    ) { _ in
        state.update { state in
            defer { state.hitCounts.removeAll(keepingCapacity: true) }
            var foundNewBucket = false
            // Every (edge, bucket) the run witnessed — not just the new ones;
            // ownership accounting decides novelty, the vocabulary just
            // describes the run.
            var features: [UInt64] = []
            features.reserveCapacity(state.hitCounts.count)
            for (edge, count) in state.hitCounts {
                let bucket = bucketBit(forHitCount: count)
                features.append(UInt64(edge) << 8 | UInt64(bucket))
                if state.seenBuckets[edge, default: 0] & bucket == 0 {
                    state.seenBuckets[edge, default: 0] |= bucket
                    foundNewBucket = true
                }
            }
            if foundNewBucket { state.lastFeatures = features }
            return foundNewBucket
        }
    }
}
