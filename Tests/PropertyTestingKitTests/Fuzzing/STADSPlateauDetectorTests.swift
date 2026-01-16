//
//  STADSPlateauDetectorTests.swift
//  PropertyTestingKit
//

import Testing
import Foundation
@testable import PropertyTestingKit

@Suite("STADSPlateauDetector")
struct STADSPlateauDetectorTests {

    @Test("Detector starts in non-plateau state")
    func testInitialState() async {
        let config = STADSPlateauDetector.Config(
            minDiscoveryProbability: 0.01,
            confirmationChecks: 2,
            checkInterval: 10,
            enabled: true
        )
        let detector = STADSPlateauDetector(config: config)

        #expect(!detector.hasPlateaued)
        let stats = detector.stats()
        #expect(stats.totalObservations == 0)
        #expect(stats.totalDiscoveries == 0)
        #expect(stats.singletonCount == 0)
    }

    @Test("Detector detects plateau after no discoveries")
    func testDetectsPlateauNoDiscoveries() async {
        let config = STADSPlateauDetector.Config(
            minDiscoveryProbability: 0.01,
            confirmationChecks: 2,
            checkInterval: 10,
            enabled: true
        )
        var detector = STADSPlateauDetector(config: config)

        // Record many non-discoveries
        // Need at least checkInterval * confirmationChecks iterations
        for _ in 0..<50 {
            detector.record(discoveredNewCoverage: false)
        }

        #expect(detector.hasPlateaued)
        #expect(detector.discoveryProbability < config.minDiscoveryProbability)
    }

    @Test("Detector does not plateau with continuous discoveries")
    func testNoPlateauWithDiscoveries() async {
        let config = STADSPlateauDetector.Config(
            minDiscoveryProbability: 0.01,
            confirmationChecks: 2,
            checkInterval: 10,
            enabled: true
        )
        var detector = STADSPlateauDetector(config: config)

        // Record discoveries at a good rate (20%)
        for i in 0..<100 {
            detector.record(discoveredNewCoverage: i % 5 == 0)
        }

        #expect(!detector.hasPlateaued)
        let stats = detector.stats()
        #expect(stats.totalDiscoveries == 20)
    }

    @Test("Detector respects enabled flag")
    func testDisabledDetector() async {
        let config = STADSPlateauDetector.Config(
            minDiscoveryProbability: 0.01,
            confirmationChecks: 1,
            checkInterval: 5,
            enabled: false
        )
        var detector = STADSPlateauDetector(config: config)

        // Record many non-discoveries
        for _ in 0..<100 {
            detector.record(discoveredNewCoverage: false)
        }

        // Should never plateau when disabled
        #expect(!detector.hasPlateaued)
    }

    @Test("Good-Turing probability decreases with no new discoveries")
    func testProbabilityDecreases() async {
        let config = STADSPlateauDetector.Config(
            minDiscoveryProbability: 0.001,
            confirmationChecks: 10,
            checkInterval: 10,
            enabled: true
        )
        var detector = STADSPlateauDetector(config: config)

        // Start with some discoveries
        for _ in 0..<5 {
            detector.record(discoveredNewCoverage: true)
        }

        let initialProbability = detector.discoveryProbability

        // Then only non-discoveries
        for _ in 0..<100 {
            detector.record(discoveredNewCoverage: false)
        }

        let finalProbability = detector.discoveryProbability

        #expect(finalProbability < initialProbability)
    }

    @Test("Stats track discoveries correctly")
    func testStatsTracking() async {
        let config = STADSPlateauDetector.Config(
            checkInterval: 100,
            enabled: true
        )
        var detector = STADSPlateauDetector(config: config)

        detector.record(discoveredNewCoverage: true)
        detector.record(discoveredNewCoverage: false)
        detector.record(discoveredNewCoverage: true)
        detector.record(discoveredNewCoverage: false)
        detector.record(discoveredNewCoverage: true)

        let stats = detector.stats()
        #expect(stats.totalObservations == 5)
        #expect(stats.totalDiscoveries == 3)
    }

    @Test("Summary includes probability information")
    func testSummary() async {
        let config = STADSPlateauDetector.Config(
            checkInterval: 5,
            enabled: true
        )
        var detector = STADSPlateauDetector(config: config)

        for _ in 0..<10 {
            detector.record(discoveredNewCoverage: false)
        }

        let summary = detector.summary(includeDetails: true)
        #expect(summary.contains("P(new)"))
        #expect(summary.contains("singletons"))
    }

    @Test("Signature-based recording tracks frequencies correctly")
    func testSignatureRecording() async {
        let config = STADSPlateauDetector.Config(
            checkInterval: 100,
            enabled: true
        )
        var detector = STADSPlateauDetector(config: config)

        // Record same signature multiple times
        detector.record(signatureHash: 12345)
        detector.record(signatureHash: 12345)
        detector.record(signatureHash: 12345)

        // Record new signature
        detector.record(signatureHash: 67890)

        let stats = detector.stats()
        #expect(stats.totalDiscoveries == 2) // Two unique signatures
        #expect(stats.singletonCount == 1) // Only 67890 is a singleton
    }
}

@Suite("STADSPlugin")
struct STADSPluginTests {

    @Test("Plugin has correct ID")
    func testPluginId() async {
        let plugin = STADSPlugin()
        #expect(await plugin.id == "stads_detector")
    }

    @Test("Plugin returns stop action when plateaued")
    func testStopAction() async throws {
        let config = STADSPlateauDetector.Config(
            minDiscoveryProbability: 0.01,
            confirmationChecks: 2,
            checkInterval: 5,
            enabled: true
        )
        let plugin = STADSPlugin(config: config)

        // Record many non-discoveries via iteration events
        for i in 0..<50 {
            let iterationContext = PluginEvent<Int>.IterationContext(
                discoveredNewCoverage: false,
                input: i
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
        let plugin: STADSPlugin = .stadsDetector(
            minDiscoveryProbability: 0.005,
            confirmationChecks: 5,
            checkInterval: 50
        )

        #expect(await plugin.id == "stads_detector")
    }
}
