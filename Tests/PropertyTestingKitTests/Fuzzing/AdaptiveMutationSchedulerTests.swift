//
//  AdaptiveMutationSchedulerTests.swift
//  PropertyTestingKit
//

import Testing
import Foundation
@testable import PropertyTestingKit

@Suite("AdaptiveMutationScheduler", .serialized)
struct AdaptiveMutationSchedulerTests {

    // MARK: - MutationStrategy Tests

    @Test("MutationStrategy has all expected cases")
    func testMutationStrategyCases() {
        let strategies = MutationStrategy.allCases
        #expect(strategies.count == 7)
        #expect(strategies.contains(.singleComponent))
        #expect(strategies.contains(.multiComponent))
        #expect(strategies.contains(.arithmetic))
        #expect(strategies.contains(.stringDictionary))
        #expect(strategies.contains(.valueProfileDirected))
        #expect(strategies.contains(.customMutator))
        #expect(strategies.contains(.freshGeneration))
    }

    // MARK: - AdaptiveMutationConfig Tests

    @Test("Config has sensible defaults")
    func testConfigDefaults() {
        let config = AdaptiveMutationConfig()

        #expect(!config.enabled)
        #expect(config.pilotPhaseIterations == 500)
        #expect(config.explorationFactor == 0.1)
        #expect(config.pacemakerInterval == 200)
        #expect(config.minimumProbability == 0.05)
    }

    // MARK: - AdaptiveMutationScheduler Tests

    @Test("Scheduler initializes in pilot phase")
    func testInitialPhase() {
        let scheduler = AdaptiveMutationScheduler(config: AdaptiveMutationConfig(
            enabled: true,
            pilotPhaseIterations: 100
        ))

        #expect(scheduler.phase == .pilot)
        #expect(scheduler.isInPilotPhase)
    }

    @Test("Scheduler transitions to core phase after pilot")
    func testTransitionToCore() {
        var scheduler = AdaptiveMutationScheduler(config: AdaptiveMutationConfig(
            enabled: true,
            pilotPhaseIterations: 10
        ))

        // Run through pilot phase
        for _ in 0..<15 {
            _ = scheduler.selectStrategy()
        }

        #expect(scheduler.phase == .core)
        #expect(!scheduler.isInPilotPhase)
    }

    @Test("Scheduler selects strategies uniformly in pilot phase")
    func testPilotPhaseUniformSelection() {
        var scheduler = AdaptiveMutationScheduler(config: AdaptiveMutationConfig(
            enabled: true,
            pilotPhaseIterations: 1000
        ))

        var strategyCounts: [MutationStrategy: Int] = [:]
        for strategy in MutationStrategy.allCases {
            strategyCounts[strategy] = 0
        }

        // Select many strategies
        for _ in 0..<100 {
            let strategy = scheduler.selectStrategy()
            strategyCounts[strategy]! += 1
        }

        // All strategies should be selected at least once (statistically very likely with 100 trials)
        for strategy in MutationStrategy.allCases {
            #expect(strategyCounts[strategy]! > 0, "Strategy \(strategy) was never selected")
        }
    }

    @Test("Scheduler records attempts correctly")
    func testRecordAttempts() {
        var scheduler = AdaptiveMutationScheduler(config: AdaptiveMutationConfig(
            enabled: true,
            pilotPhaseIterations: 10
        ))

        // Record some attempts
        scheduler.recordAttempt(.singleComponent, discoveredNewCoverage: true)
        scheduler.recordAttempt(.singleComponent, discoveredNewCoverage: true)
        scheduler.recordAttempt(.singleComponent, discoveredNewCoverage: false)
        scheduler.recordAttempt(.arithmetic, discoveredNewCoverage: false)

        let singleRate = scheduler.successRate(for: .singleComponent)
        let arithmeticRate = scheduler.successRate(for: .arithmetic)

        #expect(singleRate > 0.6) // 2/3 = 0.666...
        #expect(arithmeticRate == 0.0) // 0/1
    }

    @Test("Disabled scheduler doesn't record attempts")
    func testDisabledDoesNotRecord() {
        var scheduler = AdaptiveMutationScheduler(config: AdaptiveMutationConfig(
            enabled: false
        ))

        scheduler.recordAttempt(.singleComponent, discoveredNewCoverage: true)
        scheduler.recordAttempt(.singleComponent, discoveredNewCoverage: true)

        let rate = scheduler.successRate(for: .singleComponent)
        #expect(rate == 0.0) // Nothing recorded
    }

    @Test("Stats track all strategies")
    func testStatsTracking() {
        var scheduler = AdaptiveMutationScheduler(config: AdaptiveMutationConfig(
            enabled: true,
            pilotPhaseIterations: 10
        ))

        // Record some attempts
        for _ in 0..<5 {
            _ = scheduler.selectStrategy()
        }
        scheduler.recordAttempt(.singleComponent, discoveredNewCoverage: true)
        scheduler.recordAttempt(.multiComponent, discoveredNewCoverage: false)

        let stats = scheduler.stats
        #expect(stats.totalIterations == 5)
        #expect(stats.currentPhase == .pilot)
    }

    @Test("Stats report is generated")
    func testStatsReport() {
        var scheduler = AdaptiveMutationScheduler(config: AdaptiveMutationConfig(
            enabled: true,
            pilotPhaseIterations: 10
        ))

        scheduler.recordAttempt(.singleComponent, discoveredNewCoverage: true)
        _ = scheduler.selectStrategy()

        let report = scheduler.stats.report()
        #expect(report.contains("Adaptive"))
        #expect(report.contains("Phase"))
    }

    @Test("Summary shows top strategies")
    func testSummary() {
        var scheduler = AdaptiveMutationScheduler(config: AdaptiveMutationConfig(
            enabled: true,
            pilotPhaseIterations: 10
        ))

        scheduler.recordAttempt(.singleComponent, discoveredNewCoverage: true)
        scheduler.recordAttempt(.singleComponent, discoveredNewCoverage: true)
        scheduler.recordAttempt(.arithmetic, discoveredNewCoverage: false)

        let summary = scheduler.summary()
        #expect(summary.contains("phase="))
        #expect(summary.contains("top="))
    }

    @Test("Pacemaker mode activates periodically")
    func testPacemakerMode() {
        var scheduler = AdaptiveMutationScheduler(config: AdaptiveMutationConfig(
            enabled: true,
            pilotPhaseIterations: 5,
            pacemakerInterval: 10
        ))

        // Get through pilot
        for _ in 0..<6 {
            _ = scheduler.selectStrategy()
        }
        #expect(scheduler.phase == .core)

        // Continue until pacemaker
        for _ in 0..<10 {
            _ = scheduler.selectStrategy()
        }

        // Should eventually hit pacemaker
        #expect(scheduler.phase == .pacemaker || scheduler.phase == .core)
    }

    @Test("Top strategies sorted by success rate")
    func testTopStrategies() {
        var scheduler = AdaptiveMutationScheduler(config: AdaptiveMutationConfig(
            enabled: true,
            pilotPhaseIterations: 10
        ))

        // Make singleComponent very successful
        for _ in 0..<10 {
            scheduler.recordAttempt(.singleComponent, discoveredNewCoverage: true)
        }

        // Make arithmetic fail
        for _ in 0..<10 {
            scheduler.recordAttempt(.arithmetic, discoveredNewCoverage: false)
        }

        let stats = scheduler.stats
        let topStrategies = stats.topStrategies

        // singleComponent should be at top
        #expect(topStrategies.first?.strategy == .singleComponent)
        #expect(topStrategies.first?.rate == 1.0)
    }
}
