//
//  CoveragePlateauDetectorTests.swift
//  PropertyTestingKit
//

import Testing
import Foundation
@testable import PropertyTestingKit

@Suite("CoveragePlateauDetector", .serialized)
struct CoveragePlateauDetectorTests {

    @Test("Detector starts in non-plateau state")
    func testInitialState() {
        let config = CoveragePlateauDetector.Config(
            windowSize: 10,
            minDiscoveryRate: 0.01,
            confirmationWindows: 2,
            enabled: true
        )
        let detector = CoveragePlateauDetector(config: config)

        #expect(!detector.hasPlateaued)
        #expect(detector.stats.totalIterations == 0)
        #expect(detector.stats.totalDiscoveries == 0)
    }

    @Test("Detector detects plateau after no discoveries")
    func testDetectsPlateau() {
        let config = CoveragePlateauDetector.Config(
            windowSize: 5,
            minDiscoveryRate: 0.01,
            confirmationWindows: 2,
            enabled: true
        )
        var detector = CoveragePlateauDetector(config: config)

        // Record many non-discoveries
        for _ in 0..<20 {
            detector.record(discoveredNewCoverage: false)
        }

        #expect(detector.hasPlateaued)
    }

    @Test("Detector does not plateau with continuous discoveries")
    func testNoPlateauWithDiscoveries() {
        let config = CoveragePlateauDetector.Config(
            windowSize: 10,
            minDiscoveryRate: 0.05,
            confirmationWindows: 2,
            enabled: true
        )
        var detector = CoveragePlateauDetector(config: config)

        // Record discoveries at a good rate
        for i in 0..<50 {
            detector.record(discoveredNewCoverage: i % 5 == 0)
        }

        #expect(!detector.hasPlateaued)
    }

    @Test("Detector respects enabled flag")
    func testDisabledDetector() {
        let config = CoveragePlateauDetector.Config(
            windowSize: 5,
            minDiscoveryRate: 0.01,
            confirmationWindows: 2,
            enabled: false
        )
        var detector = CoveragePlateauDetector(config: config)

        // Record many non-discoveries
        for _ in 0..<100 {
            detector.record(discoveredNewCoverage: false)
        }

        // Should never plateau when disabled
        #expect(!detector.hasPlateaued)
    }

    @Test("Stats track discoveries correctly")
    func testStatsTracking() {
        let config = CoveragePlateauDetector.Config(
            windowSize: 10,
            minDiscoveryRate: 0.01,
            confirmationWindows: 2,
            enabled: true
        )
        var detector = CoveragePlateauDetector(config: config)

        detector.record(discoveredNewCoverage: true)
        detector.record(discoveredNewCoverage: false)
        detector.record(discoveredNewCoverage: true)
        detector.record(discoveredNewCoverage: false)
        detector.record(discoveredNewCoverage: false)

        let stats = detector.stats
        #expect(stats.totalIterations == 5)
        #expect(stats.totalDiscoveries == 2)
        #expect(stats.overallRate == 0.4)
    }

    @Test("Summary includes rate information")
    func testSummary() {
        let config = CoveragePlateauDetector.Config(
            windowSize: 10,
            minDiscoveryRate: 0.01,
            confirmationWindows: 2,
            enabled: true
        )
        var detector = CoveragePlateauDetector(config: config)

        for _ in 0..<15 {
            detector.record(discoveredNewCoverage: false)
        }

        let summary = detector.summary(includeDetails: true)
        #expect(summary.contains("rate"))
    }

    @Test("Plateau resets after discovery burst")
    func testPlateauResets() {
        let config = CoveragePlateauDetector.Config(
            windowSize: 5,
            minDiscoveryRate: 0.01,
            confirmationWindows: 1,
            enabled: true
        )
        var detector = CoveragePlateauDetector(config: config)

        // Record non-discoveries to approach plateau
        for _ in 0..<10 {
            detector.record(discoveredNewCoverage: false)
        }

        // Then record some discoveries
        for _ in 0..<3 {
            detector.record(discoveredNewCoverage: true)
        }

        // Rate should improve
        #expect(detector.stats.windowRate > 0)
    }
}
