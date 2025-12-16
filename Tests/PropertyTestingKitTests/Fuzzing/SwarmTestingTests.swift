//
//  SwarmTestingTests.swift
//  PropertyTestingKit
//

import Testing
import Foundation
@testable import PropertyTestingKit

@Suite("SwarmTesting")
struct SwarmTestingTests {

    // MARK: - SwarmConfig Tests

    @Test("SwarmConfig has sensible defaults")
    func testSwarmConfigDefaults() {
        let config = SwarmConfig()

        #expect(!config.enabled)
        #expect(config.mutatorInclusionProbability == 0.5)
        #expect(config.configurationWindow == 500)
        #expect(config.minActiveMutators == 1)
        #expect(config.maxActiveMutators == nil)
    }

    // MARK: - SwarmConfiguration Tests

    @Test("SwarmConfiguration tracks active categories")
    func testSwarmConfiguration() {
        let config = SwarmConfiguration(activeCategories: [.singleComponent, .arithmetic])

        #expect(config.isActive(.singleComponent))
        #expect(config.isActive(.arithmetic))
        #expect(!config.isActive(.dictionary))
    }

    @Test("SwarmConfiguration description lists categories")
    func testSwarmConfigurationDescription() {
        let config = SwarmConfiguration(activeCategories: [.singleComponent, .boundary])

        let desc = config.description
        #expect(desc.contains("singleComponent"))
        #expect(desc.contains("boundary"))
    }

    // MARK: - SwarmScheduler Tests

    @Test("Scheduler returns nil when disabled")
    func testSchedulerDisabled() {
        var scheduler = SwarmScheduler(config: SwarmConfig(enabled: false))

        let changed = scheduler.updateConfiguration()
        #expect(!changed)
        #expect(scheduler.current == nil)
    }

    @Test("Scheduler samples configuration when enabled")
    func testSchedulerSamplesConfiguration() {
        var scheduler = SwarmScheduler(config: SwarmConfig(
            enabled: true,
            configurationWindow: 10
        ))

        let changed = scheduler.updateConfiguration()
        #expect(changed)
        #expect(scheduler.current != nil)
    }

    @Test("Scheduler respects minimum mutators constraint")
    func testSchedulerMinMutators() {
        var scheduler = SwarmScheduler(config: SwarmConfig(
            enabled: true,
            mutatorInclusionProbability: 0.0, // Would exclude all
            minActiveMutators: 2
        ))

        _ = scheduler.updateConfiguration()
        let config = scheduler.current

        #expect(config != nil)
        #expect(config!.activeCategories.count >= 2)
    }

    @Test("Scheduler respects maximum mutators constraint")
    func testSchedulerMaxMutators() {
        var scheduler = SwarmScheduler(config: SwarmConfig(
            enabled: true,
            mutatorInclusionProbability: 1.0, // Would include all
            maxActiveMutators: 3
        ))

        _ = scheduler.updateConfiguration()
        let config = scheduler.current

        #expect(config != nil)
        #expect(config!.activeCategories.count <= 3)
    }

    @Test("Scheduler resamples after window")
    func testSchedulerResamples() {
        var scheduler = SwarmScheduler(config: SwarmConfig(
            enabled: true,
            configurationWindow: 5
        ))

        // First configuration
        _ = scheduler.updateConfiguration()
        _ = scheduler.current  // Just verify it exists

        // Updates within window don't change
        for _ in 0..<4 {
            let changed = scheduler.updateConfiguration()
            #expect(!changed)
        }

        // Window boundary triggers resample
        let changed = scheduler.updateConfiguration()
        #expect(changed)

        // May or may not be different (random)
        #expect(scheduler.current != nil)
    }

    @Test("shouldApply returns true when disabled")
    func testShouldApplyWhenDisabled() {
        let scheduler = SwarmScheduler(config: SwarmConfig(enabled: false))

        #expect(scheduler.shouldApply(.singleComponent))
        #expect(scheduler.shouldApply(.dictionary))
    }

    @Test("shouldApply respects configuration")
    func testShouldApplyRespectsConfig() {
        var scheduler = SwarmScheduler(config: SwarmConfig(
            enabled: true,
            mutatorInclusionProbability: 1.0 // Include all
        ))

        _ = scheduler.updateConfiguration()

        // All should be active
        for category in MutatorCategory.allCases {
            #expect(scheduler.shouldApply(category))
        }
    }

    @Test("Scheduler records coverage hits")
    func testRecordsCoverageHits() {
        var scheduler = SwarmScheduler(config: SwarmConfig(
            enabled: true,
            configurationWindow: 100
        ))

        _ = scheduler.updateConfiguration()
        scheduler.recordCoverageHit()
        scheduler.recordCoverageHit()

        let stats = scheduler.stats
        let totalHits = stats.coverageHitsPerConfig.values.reduce(0, +)
        #expect(totalHits == 2)
    }

    @Test("Stats report includes configuration info")
    func testStatsReport() {
        var scheduler = SwarmScheduler(config: SwarmConfig(
            enabled: true,
            configurationWindow: 100
        ))

        _ = scheduler.updateConfiguration()
        scheduler.recordCoverageHit()

        let report = scheduler.stats.report()
        #expect(report.contains("Swarm"))
    }

    @Test("Summary shows current configuration")
    func testSummary() {
        var scheduler = SwarmScheduler(config: SwarmConfig(
            enabled: true,
            configurationWindow: 100
        ))

        _ = scheduler.updateConfiguration()
        let summary = scheduler.summary()
        #expect(summary.contains("swarm="))
    }

    @Test("Summary shows disabled when not enabled")
    func testSummaryDisabled() {
        let scheduler = SwarmScheduler(config: SwarmConfig(enabled: false))
        let summary = scheduler.summary()
        #expect(summary.contains("disabled"))
    }
}
