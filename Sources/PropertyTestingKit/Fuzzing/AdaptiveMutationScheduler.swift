//
//  AdaptiveMutationScheduler.swift
//  PropertyTestingKit
//
//  MOPT-style adaptive mutation scheduling.
//
//  Based on:
//  - Lyu et al. (2019) "MOPT: Optimized Mutation Scheduling for Fuzzers"
//
//  The key insight is that different mutation strategies are effective
//  on different targets. By tracking which strategies discover new coverage,
//  we can dynamically adjust selection probabilities to focus on what works.
//

import Foundation

// MARK: - MutationStrategy

/// Categories of mutation strategies that can be tracked and scheduled.
///
/// Maps to PropertyTestingKit's mutation operators for effectiveness tracking.
public enum MutationStrategy: String, Hashable, Sendable, CaseIterable {
    /// Single-component mutations (mutate one input field)
    case singleComponent

    /// Multi-component mutations (mutate multiple fields together)
    case multiComponent

    /// Arithmetic relationship mutations for numeric pairs
    case arithmetic

    /// Dictionary-based mutations using captured strings
    case stringDictionary

    /// Value profile-directed mutations toward comparison targets
    case valueProfileDirected

    /// Custom mutator-based mutations
    case customMutator

    /// Fresh generation from fuzz values
    case freshGeneration
}

// MARK: - AdaptiveMutationConfig

/// Configuration for adaptive mutation scheduling.
public struct AdaptiveMutationConfig: Sendable, Codable {
    /// Enable adaptive mutation scheduling (MOPT-style).
    public var enabled: Bool

    /// Pilot phase iterations before starting adaptation.
    /// During pilot phase, all strategies are tried uniformly.
    public var pilotPhaseIterations: Int

    /// Exploration bonus to prevent premature convergence (0.0-1.0).
    /// Higher values maintain more exploration; lower values exploit more.
    public var explorationFactor: Double

    /// Pacemaker interval: switch to uniform every N iterations.
    /// Prevents getting stuck in local optima.
    public var pacemakerInterval: Int

    /// Minimum selection probability for any strategy.
    /// Ensures all strategies get some attempts.
    public var minimumProbability: Double

    public init(
        enabled: Bool = false,
        pilotPhaseIterations: Int = 500,
        explorationFactor: Double = 0.1,
        pacemakerInterval: Int = 200,
        minimumProbability: Double = 0.05
    ) {
        self.enabled = enabled
        self.pilotPhaseIterations = pilotPhaseIterations
        self.explorationFactor = explorationFactor
        self.pacemakerInterval = pacemakerInterval
        self.minimumProbability = minimumProbability
    }
}

// MARK: - AdaptiveMutationScheduler

/// MOPT-inspired adaptive mutation scheduler.
///
/// Tracks which mutation strategies discover new coverage and adjusts
/// selection probabilities to favor effective strategies.
///
/// ## Algorithm
///
/// 1. **Pilot Phase**: First N iterations use uniform random selection
///    to gather baseline effectiveness data for all strategies.
///
/// 2. **Core Phase**: Uses learned weights based on success rates.
///    P(strategy) = (success_rate + exploration_bonus) / sum_weights
///
/// 3. **Pacemaker Mode**: Periodically reverts to uniform selection
///    to prevent getting stuck in local optima.
public struct AdaptiveMutationScheduler: Sendable {
    private let config: AdaptiveMutationConfig

    /// Per-strategy statistics: (coverage hits, total attempts)
    private var strategyStats: [MutationStrategy: (hits: Int, attempts: Int)] = [:]

    /// Total iterations processed.
    private var totalIterations: Int = 0

    /// Iterations since last pacemaker reset.
    private var iterationsSincePacemaker: Int = 0

    /// Whether currently in pacemaker mode.
    private var inPacemakerMode: Bool = false

    public init(config: AdaptiveMutationConfig = AdaptiveMutationConfig()) {
        self.config = config

        // Initialize all strategies with zero stats
        for strategy in MutationStrategy.allCases {
            strategyStats[strategy] = (hits: 0, attempts: 0)
        }
    }

    // MARK: - Phase Management

    /// Current scheduling phase.
    public var phase: SchedulingPhase {
        if totalIterations < config.pilotPhaseIterations {
            return .pilot
        } else if inPacemakerMode {
            return .pacemaker
        } else {
            return .core
        }
    }

    /// Whether we're in the pilot phase (uniform selection).
    public var isInPilotPhase: Bool {
        totalIterations < config.pilotPhaseIterations
    }

    // MARK: - Strategy Selection

    /// Select a mutation strategy based on current phase and learned weights.
    ///
    /// - Returns: The selected strategy.
    public mutating func selectStrategy() -> MutationStrategy {
        totalIterations += 1
        iterationsSincePacemaker += 1

        // Check for pacemaker mode activation
        if !isInPilotPhase && iterationsSincePacemaker >= config.pacemakerInterval {
            inPacemakerMode = true
            iterationsSincePacemaker = 0
        } else if inPacemakerMode && iterationsSincePacemaker >= config.pacemakerInterval / 4 {
            // Exit pacemaker after brief uniform period
            inPacemakerMode = false
            iterationsSincePacemaker = 0
        }

        switch phase {
        case .pilot, .pacemaker:
            // Uniform random selection
            return MutationStrategy.allCases.randomElement()!

        case .core:
            // Weighted selection based on learned effectiveness
            return weightedSelection()
        }
    }

    /// Weighted selection based on success rates.
    private func weightedSelection() -> MutationStrategy {
        let weights = computeWeights()
        let totalWeight = weights.values.reduce(0, +)

        guard totalWeight > 0 else {
            return MutationStrategy.allCases.randomElement()!
        }

        var random = Double.random(in: 0..<totalWeight)
        for (strategy, weight) in weights {
            random -= weight
            if random <= 0 {
                return strategy
            }
        }

        return MutationStrategy.allCases.last!
    }

    /// Compute selection weights based on success rates with exploration bonus.
    private func computeWeights() -> [MutationStrategy: Double] {
        var weights: [MutationStrategy: Double] = [:]

        for strategy in MutationStrategy.allCases {
            let rate = successRate(for: strategy)
            // Weight = success_rate + exploration_bonus, with minimum floor
            let weight = max(rate + config.explorationFactor, config.minimumProbability)
            weights[strategy] = weight
        }

        return weights
    }

    // MARK: - Effectiveness Tracking

    /// Record the result of a mutation attempt.
    ///
    /// - Parameters:
    ///   - strategy: The strategy that was used.
    ///   - discoveredNewCoverage: Whether the mutation discovered new coverage.
    public mutating func recordAttempt(_ strategy: MutationStrategy, discoveredNewCoverage: Bool) {
        guard config.enabled else { return }

        let (hits, attempts) = strategyStats[strategy, default: (0, 0)]
        strategyStats[strategy] = (
            hits: hits + (discoveredNewCoverage ? 1 : 0),
            attempts: attempts + 1
        )
    }

    /// Success rate for a given strategy.
    public func successRate(for strategy: MutationStrategy) -> Double {
        guard let (hits, attempts) = strategyStats[strategy], attempts > 0 else {
            return 0.0
        }
        return Double(hits) / Double(attempts)
    }

    // MARK: - Statistics

    /// Statistics about adaptive mutation scheduling.
    public var stats: AdaptiveMutationStats {
        var rates: [MutationStrategy: Double] = [:]
        var attempts: [MutationStrategy: Int] = [:]

        for (strategy, (hits, att)) in strategyStats {
            rates[strategy] = att > 0 ? Double(hits) / Double(att) : 0
            attempts[strategy] = att
        }

        return AdaptiveMutationStats(
            totalIterations: totalIterations,
            currentPhase: phase,
            successRates: rates,
            totalAttempts: attempts,
            pilotIterations: config.pilotPhaseIterations
        )
    }

    /// Generate a summary string for logging.
    public func summary() -> String {
        let topStrategies = strategyStats
            .sorted { ($0.value.0, -$0.value.1) > ($1.value.0, -$1.value.1) }
            .prefix(3)
            .map { "\($0.key.rawValue):\(String(format: "%.1f%%", successRate(for: $0.key) * 100))" }
            .joined(separator: ", ")

        return "phase=\(phase.rawValue), top=[\(topStrategies)]"
    }
}

// MARK: - SchedulingPhase

/// Current phase of adaptive mutation scheduling.
public enum SchedulingPhase: String, Sendable {
    /// Pilot phase: uniform selection to gather baseline data.
    case pilot

    /// Core phase: weighted selection based on learned effectiveness.
    case core

    /// Pacemaker phase: periodic uniform selection to prevent stagnation.
    case pacemaker
}

// MARK: - AdaptiveMutationStats

/// Statistics about adaptive mutation scheduling effectiveness.
public struct AdaptiveMutationStats: Sendable {
    /// Total iterations processed.
    public let totalIterations: Int

    /// Current scheduling phase.
    public let currentPhase: SchedulingPhase

    /// Success rate per strategy.
    public let successRates: [MutationStrategy: Double]

    /// Total attempts per strategy.
    public let totalAttempts: [MutationStrategy: Int]

    /// Configured pilot phase iterations.
    public let pilotIterations: Int

    /// Top strategies by success rate.
    public var topStrategies: [(strategy: MutationStrategy, rate: Double)] {
        successRates
            .map { ($0.key, $0.value) }
            .sorted { $0.1 > $1.1 }
    }

    /// Generate a report string.
    public func report() -> String {
        var lines: [String] = []
        lines.append("Adaptive Mutation Statistics:")
        lines.append("  Phase: \(currentPhase.rawValue)")
        lines.append("  Iterations: \(totalIterations) (pilot: \(pilotIterations))")
        lines.append("  Strategy effectiveness:")

        for (strategy, rate) in topStrategies {
            let attempts = totalAttempts[strategy] ?? 0
            lines.append("    \(strategy.rawValue): \(String(format: "%.2f%%", rate * 100)) (\(attempts) attempts)")
        }

        return lines.joined(separator: "\n")
    }
}
