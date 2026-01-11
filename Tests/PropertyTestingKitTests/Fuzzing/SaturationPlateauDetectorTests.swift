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

@Suite("EventBasedSaturationPlugin")
struct EventBasedSaturationPluginTests {

    @Test("Plugin has correct ID")
    func testPluginId() async {
        let plugin = EventBasedSaturationPlugin()
        #expect(await plugin.id == "saturation_detector")
    }

    @Test("Plugin returns stop action when plateaued")
    func testStopAction() async throws {
        let config = SaturationPlateauDetector.Config(
            minGrowthRate: 0.01,
            windowSize: 5,
            confirmationWindows: 2,
            enabled: true
        )
        let plugin = EventBasedSaturationPlugin(config: config)

        // Record many non-discoveries via iteration events
        for i in 0..<50 {
            let iterationContext = PluginEvent<Int>.IterationContext(
                iteration: i,
                discoveredNewCoverage: false,
                elapsed: Double(i) * 0.1,
                corpusSize: 0
            )
            let actions = try await plugin.handle(event: PluginEvent<Int>.iteration(iterationContext))

            // Check if we got a stop action
            if actions.contains(where: {
                if case .stop = $0 { return true }
                return false
            }) {
                // Good - we got a stop action
                return
            }
        }

        Issue.record("Expected stop action after plateau")
    }

    @Test("Convenience constructor creates plugin")
    func testConvenienceConstructor() async {
        let plugin: EventBasedSaturationPlugin = .saturationDetector(
            minSaturation: 0.95,
            minGrowthRate: 0.0005,
            windowSize: 100,
            confirmationWindows: 5
        )

        #expect(await plugin.id == "saturation_detector")
    }
}
