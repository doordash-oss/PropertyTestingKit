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

//  Strategy-defined ledger features: a coverage strategy can publish the
//  vocabulary the pool culls on (pathTrie: sliding k-grams of the ordered
//  first-hit path; hitCountBuckets: (edge, bucket) pairs), instead of the
//  ledger always falling back to bare edge indices.
//

import Testing
import EdgeHooks
import SanCovHooks
@testable import PropertyTestingKit

@Suite("Strategy-defined ledger features")
struct StrategyFeatureTests {

    // MARK: - Gram hashing

    @Test("The gram hash is deterministic across calls")
    func gramHashDeterministic() {
        #expect(PathGrams.gramHash([1, 2, 3]) == PathGrams.gramHash([1, 2, 3]))
    }

    @Test("The gram hash is position-dependent")
    func gramHashPositionDependent() {
        // Order IS the signal k-grams exist to capture — a commutative mix
        // (xor of element hashes) would collapse A→B and B→A.
        #expect(PathGrams.gramHash([1, 2]) != PathGrams.gramHash([2, 1]))
    }

    @Test("Features are the sliding k-gram hashes of the path")
    func slidingGrams() {
        let features = PathGrams.features(of: [1, 2, 3], gramLength: 2)
        #expect(features == [PathGrams.gramHash([1, 2]), PathGrams.gramHash([2, 3])])
    }

    @Test("A path shorter than the gram length emits one whole-path gram")
    func shortPathWholeGram() {
        // Never zero features: an accepted input that owns nothing would be
        // uncullable dead weight under feature ownership.
        #expect(PathGrams.features(of: [7], gramLength: 4) == [PathGrams.gramHash([7])])
        #expect(PathGrams.features(of: [], gramLength: 2) == [PathGrams.gramHash([])])
    }

    // MARK: - PathTrie judge-and-collect

    @Test("A unique path judges true and yields its grams")
    func trieCollectsGramsOnUniquePath() {
        let trie = PathTrie()
        trie.advance(1)
        trie.advance(2)
        trie.advance(3)
        let grams = trie.markTerminalIfUnique(collectingGrams: 2)
        #expect(grams == PathGrams.features(of: [1, 2, 3], gramLength: 2))
    }

    @Test("A duplicate path judges nil")
    func trieDuplicatePathCollectsNil() {
        let trie = PathTrie()
        trie.advance(1)
        trie.advance(2)
        #expect(trie.markTerminalIfUnique(collectingGrams: 2) != nil)
        trie.reset()
        trie.advance(1)
        trie.advance(2)
        #expect(trie.markTerminalIfUnique(collectingGrams: 2) == nil)
    }

    @Test("Reset clears the recorded path")
    func trieResetClearsPath() {
        let trie = PathTrie()
        trie.advance(9)
        trie.reset()
        trie.advance(1)
        let grams = trie.markTerminalIfUnique(collectingGrams: 2)
        #expect(grams == PathGrams.features(of: [1], gramLength: 2),
                "edge 9 belongs to the previous iteration's path")
    }

    // MARK: - Strategy engines

    /// A decide-only harness: the built-in decisions under test never read
    /// the view, so a stub client suffices (same pattern as the
    /// hit-count-buckets engine unit tests).
    private func stubView() -> CoverageView {
        CoverageView(
            context: SanCovCounters.MeasurementContext.testInstance(),
            client: CoverageCountersClient(
                snapshotCoveredArraysWithContext: { _ in SparseCoverage() }
            )
        )
    }

    @Test("The pathTrie engine publishes k-gram features for the accepted run")
    func pathTrieEngineEmitsGrams() {
        let engine = CoverageStrategy.pathTrie.makeEngine()
        engine.onEdge?(1, true)
        engine.onEdge?(2, true)
        engine.onEdge?(1, false)  // loop re-execution: not part of the path
        engine.onEdge?(3, true)

        #expect(engine.decide(stubView()))
        #expect(engine.features?() == PathGrams.features(of: [1, 2, 3], gramLength: 2))
    }

    @Test("pathTrie's gram length is configurable")
    func pathTrieGramLengthConfigurable() {
        let engine = CoverageStrategy.pathTrie(gramLength: 3).makeEngine()
        engine.onEdge?(1, true)
        engine.onEdge?(2, true)
        engine.onEdge?(3, true)
        engine.onEdge?(4, true)

        #expect(engine.decide(stubView()))
        #expect(engine.features?() == PathGrams.features(of: [1, 2, 3, 4], gramLength: 3))
    }

    @Test("Strategies without a vocabulary publish no features")
    func newEdgeEngineHasNoVocabulary() {
        #expect(CoverageStrategy.newEdge.makeEngine().features == nil)
        #expect(CoverageStrategy.signatureMatch.makeEngine().features == nil)
    }

    @Test("The hitCountBuckets engine publishes (edge, bucket) features")
    func hitCountBucketsEngineEmitsEdgeBucketPairs() {
        let engine = CoverageStrategy.hitCountBuckets.makeEngine()
        engine.onEdge?(5, true)               // edge 5 × 1 → bucket bit 1<<0
        for hit in 0..<4 {                    // edge 9 × 4 → bucket bit 1<<3
            engine.onEdge?(9, hit == 0)
        }

        #expect(engine.decide(stubView()))
        let features = engine.features?() ?? []
        #expect(Set(features) == Set([
            UInt64(5) << 8 | 0b0000_0001,
            UInt64(9) << 8 | 0b0000_1000,
        ]))
    }

    // MARK: - Pool plumbing

    @Test("resolvedFeatures falls back to widened edge indices")
    func resolvedFeaturesFallback() {
        let fallback = PoolIterationOutcome(
            source: .generated, newCoverage: SparseCoverage(indices: [3, 7]))
        #expect(fallback.resolvedFeatures == [3, 7])

        let explicit = PoolIterationOutcome(
            source: .generated,
            newCoverage: SparseCoverage(indices: [3, 7]),
            features: [99])
        #expect(explicit.resolvedFeatures == [99])
    }

    @Test("Feature-ownership admission judges on strategy features, not edges")
    func admissionUsesStrategyFeatures() {
        let core = WeightedPoolCore(
            admission: .featureOwnership, policies: [],
            burstLength: 1, focusOnInsert: false)

        // Disjoint edge sets, identical feature: the second accept owns
        // nothing (ties don't steal) — only the vocabulary can explain a
        // rejection here.
        let first = core.observe(PoolIterationOutcome(
            source: .generated,
            newCoverage: SparseCoverage(indices: [1]),
            features: [100]))
        #expect(first == 0)
        let second = core.observe(PoolIterationOutcome(
            source: .generated,
            newCoverage: SparseCoverage(indices: [2]),
            features: [100]))
        #expect(second == nil)
    }

    @Test("Insertion notifications carry the resolved features")
    func insertedEventCarriesFeatures() {
        final class CapturePolicy: PoolPlugin {
            var insertedFeatures: [[UInt64]] = []
            func handle(event: PoolEvent) -> [PoolAction] {
                if case let .inserted(_, _, features) = event {
                    insertedFeatures.append(features)
                }
                return []
            }
        }
        let capture = CapturePolicy()
        let core = WeightedPoolCore(
            admission: .everyDiscovery, policies: [capture],
            burstLength: 1, focusOnInsert: false)

        _ = core.observe(PoolIterationOutcome(
            source: .generated,
            newCoverage: SparseCoverage(indices: [1, 2]),
            features: [42]))
        _ = core.observe(PoolIterationOutcome(
            source: .generated,
            newCoverage: SparseCoverage(indices: [1, 2])))

        #expect(capture.insertedFeatures == [[42], [1, 2]],
                "explicit vocabulary first, widened-edge fallback second")
    }
}
