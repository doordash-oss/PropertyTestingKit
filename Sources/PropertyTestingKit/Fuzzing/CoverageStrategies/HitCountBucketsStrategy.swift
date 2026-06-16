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
    ///
    /// Publishes no culling vocabulary — the pool culls on covered edges. An
    /// (edge, bucket) vocabulary is this strategy's own acceptance criterion,
    /// and a culling vocabulary equal to acceptance is a tautology: every
    /// accepted input owns a fresh feature, so culling silently turns off
    /// (measured: fsub regressed exactly to its unculled solve rate).
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
    // Per-EDGE half (onEdge/onReset): a lock-free accumulator — the SyncBox here
    // was taken ~714x per test (Finding 42). Engine-lifetime half (decide):
    // seenBuckets, touched ONLY in decide, which the fuzz loop calls serially on
    // one thread per engine — so a plain holder needs no lock. onEdge never reads
    // or writes seenBuckets, so there is no onEdge/decide race on it; stragglers
    // race only the accumulator, which is atomic.
    let hits = HitCountAccumulator()

    /// Engine-lifetime per-edge bitmask of observed buckets. Decide-only; a
    /// reference so the @Sendable decide closure can mutate it, @unchecked
    /// Sendable because decide is serialized per engine.
    final class SeenBuckets: @unchecked Sendable {
        var map: [UInt32: UInt8] = [:]
    }
    let seen = SeenBuckets()

    return CoverageEngine(
        onEdge: { edge, _ in
            hits.record(edge: edge)
        },
        onReset: {
            hits.reset()
        }
    ) { _ in
        defer { hits.reset() }
        var foundNewBucket = false
        for ec in hits.snapshot() {
            let bucket = bucketBit(forHitCount: ec.count)
            if seen.map[ec.edge, default: 0] & bucket == 0 {
                seen.map[ec.edge, default: 0] |= bucket
                foundNewBucket = true
            }
        }
        return foundNewBucket
    }
}
