//
//  EntropicSchedulerTests.swift
//  PropertyTestingKit
//

import Testing
import Foundation
@testable import PropertyTestingKit

@Suite("EntropicScheduler", .serialized)
struct EntropicSchedulerTests {

    @Test("Scheduler initializes with empty state")
    func testInitialState() {
        let scheduler = EntropicScheduler()

        let stats = scheduler.stats
        #expect(stats.totalFeatures == 0)
    }

    @Test("Scheduler records entry features")
    func testFeatureRecording() {
        var scheduler = EntropicScheduler()

        let sig1 = CoverageSignature(buckets: [0: .one, 1: .two])
        let sig2 = CoverageSignature(buckets: [0: .one, 2: .three])

        scheduler.recordEntry(sig1)
        scheduler.recordEntry(sig2)

        let stats = scheduler.stats
        #expect(stats.totalFeatures > 0)
    }

    @Test("Config has sensible defaults")
    func testConfigDefaults() {
        let config = EntropicScheduler.Config()

        #expect(config.abundanceThreshold == 0xFF)
        #expect(config.minimumEntropy == 0.1)
        #expect(config.enabled)
    }

    @Test("Disabled scheduler skips recording")
    func testDisabledScheduler() {
        var scheduler = EntropicScheduler(config: .init(enabled: false))

        let sig = CoverageSignature(buckets: [0: .one])
        scheduler.recordEntry(sig)

        let stats = scheduler.stats
        #expect(stats.totalFeatures == 0)
    }

    @Test("Entropy computation returns values")
    func testEntropyComputation() {
        let scheduler = EntropicScheduler()

        // Compute entropy for a signature
        let sig = CoverageSignature(buckets: [0: .one, 1: .two])
        let entropy = scheduler.computeEntropy(for: sig)

        // Entropy should be non-negative
        #expect(entropy >= 0)
    }

    @Test("Recompute updates entropies")
    func testRecompute() {
        var scheduler = EntropicScheduler()

        let sig = CoverageSignature(buckets: [0: .one])
        scheduler.recordEntry(sig)

        // Recompute should not crash
        scheduler.recomputeEntropies(for: [sig])

        let stats = scheduler.stats
        #expect(stats.totalFeatures > 0)
    }

    @Test("Feature extraction from signature")
    func testFeatureExtraction() {
        let sig = CoverageSignature(buckets: [0: .one, 5: .fourToSeven, 10: .oneHundredTwentyEightPlus])

        let features = EntropicScheduler.extractFeatures(from: sig)

        #expect(features.count == 3)
        #expect(features.contains(Feature(index: 0, bucket: .one)))
        #expect(features.contains(Feature(index: 5, bucket: .fourToSeven)))
        #expect(features.contains(Feature(index: 10, bucket: .oneHundredTwentyEightPlus)))
    }

    @Test("Stats track total features")
    func testStatsTotalFeatures() {
        var scheduler = EntropicScheduler()

        scheduler.recordEntry(CoverageSignature(buckets: [0: .one]))
        scheduler.recordEntry(CoverageSignature(buckets: [1: .one]))
        scheduler.recordEntry(CoverageSignature(buckets: [2: .one]))

        let stats = scheduler.stats
        #expect(stats.totalFeatures == 3)
    }

    @Test("Stats track rare features")
    func testStatsRareFeatures() {
        var scheduler = EntropicScheduler(config: .init(
            abundanceThreshold: 10
        ))

        // Add same feature multiple times (should become non-rare)
        for _ in 0..<20 {
            scheduler.recordEntry(CoverageSignature(buckets: [0: .one]))
        }

        // Add rare feature once
        scheduler.recordEntry(CoverageSignature(buckets: [99: .one]))

        // Force recomputation of rare features
        let signatures = [CoverageSignature(buckets: [99: .one])]
        scheduler.recomputeEntropies(for: signatures)

        let stats = scheduler.stats
        // Feature 99 should be rare (only 1 occurrence, below threshold of 10)
        #expect(stats.rareFeatures >= 1)
    }

    @Test("Selection with empty corpus returns nil")
    func testEmptyCorpusSelection() {
        let scheduler = EntropicScheduler()

        let selected = scheduler.selectForMutation(signatures: [])
        #expect(selected == nil)
    }

    @Test("Selection returns valid index")
    func testSelectionReturnsValidIndex() {
        var scheduler = EntropicScheduler()

        // Add some entries
        let sig1 = CoverageSignature(buckets: [0: .one])
        let sig2 = CoverageSignature(buckets: [1: .one])
        let sig3 = CoverageSignature(buckets: [2: .one])

        scheduler.recordEntry(sig1)
        scheduler.recordEntry(sig2)
        scheduler.recordEntry(sig3)

        let selected = scheduler.selectForMutation(signatures: [sig1, sig2, sig3])
        #expect(selected != nil)
        #expect(selected! >= 0 && selected! < 3)
    }
}
