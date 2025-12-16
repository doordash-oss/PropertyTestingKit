//
//  RareBranchTrackerTests.swift
//  PropertyTestingKit
//

import Testing
import Foundation
@testable import PropertyTestingKit

@Suite("RareBranchTracker")
struct RareBranchTrackerTests {

    @Test("Tracker initializes with empty state")
    func testInitialState() {
        let tracker = RareBranchTracker()

        #expect(tracker.rareCount == 0)
        #expect(tracker.rareIndices.isEmpty)
    }

    @Test("Tracker records entries correctly")
    func testRecordEntry() {
        var tracker = RareBranchTracker()

        let sig1 = CoverageSignature(buckets: [0: .one, 1: .one])
        tracker.recordEntry(sig1)

        let stats = tracker.stats
        #expect(stats.totalBranches == 2)
    }

    @Test("Tracker identifies rare branches")
    func testRareBranchIdentification() {
        var tracker = RareBranchTracker(config: .init(
            useDynamicThreshold: false,
            fixedThreshold: 2,
            minimumThreshold: 1,
            enabled: true
        ))

        // Add common branch many times
        for _ in 0..<10 {
            let sig = CoverageSignature(buckets: [0: .one])
            tracker.recordEntry(sig)
        }

        // Add rare branch once
        let rareSig = CoverageSignature(buckets: [99: .one])
        tracker.recordEntry(rareSig)

        tracker.recomputeThreshold()

        // Branch 99 should be rare
        #expect(tracker.isRare(99))
        #expect(!tracker.isRare(0))
    }

    @Test("Dynamic threshold uses power of two")
    func testDynamicThreshold() {
        var tracker = RareBranchTracker(config: .init(
            useDynamicThreshold: true,
            fixedThreshold: 5,
            minimumThreshold: 2,
            enabled: true
        ))

        // Add signatures with distinct indices to avoid duplicate keys
        for i in 0..<5 {
            let sig = CoverageSignature(buckets: [i * 10: .one, i * 10 + 1: .two])
            tracker.recordEntry(sig)
        }

        tracker.recomputeThreshold()

        // Threshold should be power of two (or the minimum threshold)
        let threshold = tracker.threshold
        #expect(threshold >= 2)
        // Power of two check: n & (n-1) == 0 for powers of two
        let isPowerOfTwo = threshold > 0 && (threshold & (threshold - 1) == 0)
        #expect(isPowerOfTwo || threshold == 2) // 2 is our minimum threshold
    }

    @Test("Update from signatures works")
    func testUpdateFromSignatures() {
        var tracker = RareBranchTracker()

        let signatures = [
            CoverageSignature(buckets: [0: .one]),
            CoverageSignature(buckets: [0: .one, 1: .one]),
            CoverageSignature(buckets: [1: .one, 2: .one])
        ]

        tracker.update(from: signatures)

        let stats = tracker.stats
        #expect(stats.totalBranches == 3) // 0, 1, 2
    }

    @Test("Rare hit count for signature")
    func testRareHitCount() {
        var tracker = RareBranchTracker(config: .init(
            useDynamicThreshold: false,
            fixedThreshold: 1,
            minimumThreshold: 1,
            enabled: true
        ))

        // Make branch 0 common
        for _ in 0..<5 {
            tracker.recordEntry(CoverageSignature(buckets: [0: .one]))
        }

        // Add rare branches
        tracker.recordEntry(CoverageSignature(buckets: [10: .one]))
        tracker.recordEntry(CoverageSignature(buckets: [11: .one]))

        tracker.recomputeThreshold()

        // Signature hitting rare branches
        let sig = CoverageSignature(buckets: [10: .one, 11: .one])
        let rareHits = tracker.rareHitCount(for: sig)

        #expect(rareHits == 2)
    }

    @Test("Disabled tracker does nothing")
    func testDisabledTracker() {
        var tracker = RareBranchTracker(config: .init(enabled: false))

        let sig = CoverageSignature(buckets: [0: .one])
        tracker.recordEntry(sig)

        #expect(tracker.rareCount == 0)
    }

    @Test("Summary includes statistics")
    func testSummary() {
        var tracker = RareBranchTracker()
        tracker.recordEntry(CoverageSignature(buckets: [0: .one]))
        tracker.recomputeThreshold()

        let summary = tracker.summary()
        #expect(summary.contains("rare"))
        #expect(summary.contains("threshold"))
    }
}
