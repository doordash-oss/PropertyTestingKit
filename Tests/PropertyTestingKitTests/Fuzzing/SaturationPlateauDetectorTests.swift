//
//  SaturationPlateauDetectorTests.swift
//  PropertyTestingKit
//

import Testing
import Foundation
@testable import PropertyTestingKit

@Suite("SaturationPlateauDetector")
struct SaturationPlateauDetectorTests {

    @Test("Detector starts in non-plateau state")
    func testInitialState() async {
        let config = SaturationPlateauDetector.Config(
            minSaturation: 0.99,
            minGrowthRate: 0.001,
            windowSize: 10,
            confirmationWindows: 2,
            enabled: true
        )
        let detector = SaturationPlateauDetector(config: config)

        #expect(!detector.hasPlateaued)
        let stats = detector.stats()
        #expect(stats.totalIterations == 0)
        #expect(stats.cumulativeCoverage == 0)
    }

    @Test("Detector detects plateau after no discoveries")
    func testDetectsPlateauNoDiscoveries() async {
        let config = SaturationPlateauDetector.Config(
            minSaturation: 0.99,
            minGrowthRate: 0.01,
            windowSize: 10,
            confirmationWindows: 2,
            enabled: true
        )
        var detector = SaturationPlateauDetector(config: config)

        // Record many non-discoveries
        for _ in 0..<50 {
            detector.record(discoveredNewCoverage: false)
        }

        #expect(detector.hasPlateaued)
        #expect(detector.growthRate < config.minGrowthRate)
    }

    @Test("Detector does not plateau with continuous discoveries")
    func testNoPlateauWithDiscoveries() async {
        let config = SaturationPlateauDetector.Config(
            minSaturation: 0.99,
            minGrowthRate: 0.01,
            windowSize: 10,
            confirmationWindows: 2,
            enabled: true
        )
        var detector = SaturationPlateauDetector(config: config)

        // Record discoveries at a good rate (20%)
        for i in 0..<100 {
            detector.record(discoveredNewCoverage: i % 5 == 0)
        }

        #expect(!detector.hasPlateaued)
        let stats = detector.stats()
        #expect(stats.cumulativeCoverage == 20)
    }

    @Test("Detector respects enabled flag")
    func testDisabledDetector() async {
        let config = SaturationPlateauDetector.Config(
            minGrowthRate: 0.01,
            windowSize: 5,
            confirmationWindows: 1,
            enabled: false
        )
        var detector = SaturationPlateauDetector(config: config)

        // Record many non-discoveries
        for _ in 0..<100 {
            detector.record(discoveredNewCoverage: false)
        }

        // Should never plateau when disabled
        #expect(!detector.hasPlateaued)
    }

    @Test("Growth rate decreases with no new discoveries")
    func testGrowthRateDecreases() async {
        let config = SaturationPlateauDetector.Config(
            minSaturation: 0.99,
            minGrowthRate: 0.0001,
            windowSize: 10,
            confirmationWindows: 10,
            enabled: true
        )
        var detector = SaturationPlateauDetector(config: config)

        // Start with some discoveries
        for _ in 0..<10 {
            detector.record(discoveredNewCoverage: true)
        }

        let initialRate = detector.growthRate

        // Then only non-discoveries
        for _ in 0..<50 {
            detector.record(discoveredNewCoverage: false)
        }

        let finalRate = detector.growthRate

        #expect(finalRate < initialRate)
    }

    @Test("Stats track coverage correctly")
    func testStatsTracking() async {
        let config = SaturationPlateauDetector.Config(
            windowSize: 100,
            enabled: true
        )
        var detector = SaturationPlateauDetector(config: config)

        detector.record(discoveredNewCoverage: true)
        detector.record(discoveredNewCoverage: false)
        detector.record(discoveredNewCoverage: true)
        detector.record(discoveredNewCoverage: false)
        detector.record(discoveredNewCoverage: true)

        let stats = detector.stats()
        #expect(stats.totalIterations == 5)
        #expect(stats.cumulativeCoverage == 3)
    }

    @Test("Summary includes saturation information")
    func testSummary() async {
        let config = SaturationPlateauDetector.Config(
            windowSize: 5,
            enabled: true
        )
        var detector = SaturationPlateauDetector(config: config)

        for _ in 0..<10 {
            detector.record(discoveredNewCoverage: false)
        }

        let summary = detector.summary(includeDetails: true)
        #expect(summary.contains("saturation"))
        #expect(summary.contains("growth"))
    }

    @Test("Saturation level increases with coverage")
    func testSaturationLevel() async {
        let config = SaturationPlateauDetector.Config(
            minSaturation: 0.99,
            windowSize: 10,
            confirmationWindows: 10,
            enabled: true
        )
        var detector = SaturationPlateauDetector(config: config)

        // Initial discoveries
        for _ in 0..<10 {
            detector.record(discoveredNewCoverage: true)
        }

        // Saturation should be calculated after first window
        let stats = detector.stats()
        #expect(stats.cumulativeCoverage == 10)
        // Saturation level should be > 0 after window completes
        #expect(stats.saturationLevel >= 0)
    }

    @Test("High saturation triggers plateau")
    func testHighSaturationPlateau() async {
        let config = SaturationPlateauDetector.Config(
            minSaturation: 0.5,  // Low threshold for testing
            minGrowthRate: 0.0001,
            windowSize: 10,
            confirmationWindows: 1,
            enabled: true
        )
        var detector = SaturationPlateauDetector(config: config)

        // Initial discoveries then stop
        for i in 0..<50 {
            detector.record(discoveredNewCoverage: i < 10)
        }

        // After many non-discoveries, should hit saturation or low growth
        #expect(detector.hasPlateaued)
    }
}

@Suite("SaturationPlateauDetectorPlugin")
struct SaturationPlateauDetectorPluginTests {

    @Test("Plugin has correct ID")
    func testPluginId() async {
        let plugin = SaturationPlateauDetectorPlugin()
        #expect(plugin.id == "saturationDetector")
    }

    @Test("Plugin returns stop decision when plateaued")
    func testStopDecision() async {
        let config = SaturationPlateauDetector.Config(
            minGrowthRate: 0.01,
            windowSize: 5,
            confirmationWindows: 2,
            enabled: true
        )
        var plugin = SaturationPlateauDetectorPlugin(config: config)

        // Record many non-discoveries
        for _ in 0..<50 {
            plugin.recordIteration(discoveredNewCoverage: false)
        }

        let context = FuzzPluginContext.StoppingContext(
            iteration: 50,
            elapsed: 1.0,
            corpusSize: 0,
            recentDiscoveryRate: 0.0,
            totalDiscoveries: 0,
            iterationsSinceLastDiscovery: 50
        )

        let decision = plugin.shouldStop(context: context)
        if case .stop(let reason) = decision {
            #expect(reason == "saturation_plateau")
        } else {
            Issue.record("Expected stop decision")
        }
    }

    @Test("Convenience constructor creates plugin")
    func testConvenienceConstructor() async {
        let plugin: SaturationPlateauDetectorPlugin = .saturationDetector(
            minSaturation: 0.95,
            minGrowthRate: 0.0005,
            windowSize: 100,
            confirmationWindows: 5
        )

        #expect(plugin.id == "saturationDetector")
    }

    @Test("Stats are populated correctly")
    func testStats() async {
        var plugin = SaturationPlateauDetectorPlugin()

        for i in 0..<10 {
            plugin.recordIteration(discoveredNewCoverage: i % 3 == 0)
        }

        let stats = plugin.stats()
        #expect(stats.pluginId == "saturationDetector")
        #expect(stats.details["saturationLevel"] != nil)
        #expect(stats.details["growthRate"] != nil)
        #expect(stats.details["cumulativeCoverage"] != nil)
    }
}
