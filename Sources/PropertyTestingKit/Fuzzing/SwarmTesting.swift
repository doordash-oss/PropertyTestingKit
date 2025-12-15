//
//  SwarmTesting.swift
//  PropertyTestingKit
//
//  Swarm testing for mutator subset selection.
//
//  Based on:
//  - Groce et al. (2012) "Swarm Testing" - ISSTA '12
//
//  The key insight is that restricting which mutation strategies are active
//  in each fuzzing window often finds more bugs than applying all mutations.
//  This happens because:
//  1. Active Suppression: Some mutations prevent bug-triggering behaviors
//  2. Feature Competition: All mutations active = shallow exploration each
//

import Foundation

// MARK: - MutatorCategory

/// Categories of mutation strategies that can be enabled/disabled by swarm testing.
///
/// These map to PropertyTestingKit's mutation operators. In swarm mode, each
/// category has a random chance of being enabled in each time window.
public enum MutatorCategory: String, Hashable, Sendable, Codable, CaseIterable {
    /// Single-component mutations (mutate one input field at a time)
    case singleComponent

    /// Multi-component mutations (mutate multiple fields together)
    case multiComponent

    /// Arithmetic relationship mutations for numeric pairs
    case arithmetic

    /// Dictionary-based mutations using captured strings
    case dictionary

    /// Value profile-directed mutations toward comparison targets
    case valueProfile

    /// Boundary value mutations (min, max, zero, overflow)
    case boundary

    /// Random/havoc mutations (aggressive random changes)
    case havoc
}

// MARK: - SwarmConfig

/// Configuration for swarm testing mode.
///
/// When enabled, swarm testing randomly enables/disables mutation strategies
/// for each fuzzing time window, improving bug detection through diversity.
public struct SwarmConfig: Sendable, Codable {
    /// Enable swarm testing mode.
    public var enabled: Bool

    /// Probability each mutation strategy is included (0.0 to 1.0).
    /// Default 0.5 based on paper's findings that balanced configurations
    /// outperform both minimal and maximal feature sets.
    public var mutatorInclusionProbability: Double

    /// How many iterations before resampling mutator configuration.
    /// Larger values allow deeper exploration per configuration.
    /// Smaller values increase configuration diversity.
    public var configurationWindow: Int

    /// Minimum number of mutation strategies to keep active.
    /// Prevents degenerate cases with zero mutators.
    public var minActiveMutators: Int

    /// Maximum number of mutation strategies to keep active.
    /// Optional limit for highly constrained exploration.
    public var maxActiveMutators: Int?

    public init(
        enabled: Bool = false,
        mutatorInclusionProbability: Double = 0.5,
        configurationWindow: Int = 500,
        minActiveMutators: Int = 1,
        maxActiveMutators: Int? = nil
    ) {
        self.enabled = enabled
        self.mutatorInclusionProbability = mutatorInclusionProbability
        self.configurationWindow = configurationWindow
        self.minActiveMutators = minActiveMutators
        self.maxActiveMutators = maxActiveMutators
    }
}

// MARK: - SwarmConfiguration

/// A specific swarm configuration: which mutator categories are active.
public struct SwarmConfiguration: Hashable, Sendable {
    /// Active mutator categories in this configuration.
    public let activeCategories: Set<MutatorCategory>

    /// When this configuration was sampled.
    public let createdAt: Date

    public init(activeCategories: Set<MutatorCategory>, createdAt: Date = Date()) {
        self.activeCategories = activeCategories
        self.createdAt = createdAt
    }

    /// Check if a category is active.
    public func isActive(_ category: MutatorCategory) -> Bool {
        activeCategories.contains(category)
    }

    /// Human-readable description.
    public var description: String {
        let names = activeCategories.map { $0.rawValue }.sorted().joined(separator: ", ")
        return "[\(names)]"
    }
}

// MARK: - SwarmScheduler

/// Manages swarm configuration sampling and tracking.
///
/// Handles configuration lifecycle:
/// 1. Sample new configurations at window boundaries
/// 2. Track which configurations find coverage/bugs
/// 3. Provide statistics for analysis
public struct SwarmScheduler: Sendable {
    private let config: SwarmConfig

    /// Current active configuration.
    private var currentConfiguration: SwarmConfiguration?

    /// Iterations since last configuration change.
    private var iterationsSinceConfigChange: Int = 0

    /// Total configurations sampled.
    private var totalConfigurations: Int = 0

    /// Coverage hits per configuration.
    private var coverageHits: [Set<MutatorCategory>: Int] = [:]

    /// Iterations per configuration.
    private var iterationsPerConfig: [Set<MutatorCategory>: Int] = [:]

    public init(config: SwarmConfig) {
        self.config = config
    }

    // MARK: - Configuration Management

    /// Update swarm configuration if needed (call each iteration).
    ///
    /// Returns true if a new configuration was sampled.
    public mutating func updateConfiguration() -> Bool {
        guard config.enabled else {
            currentConfiguration = nil
            return false
        }

        iterationsSinceConfigChange += 1

        // Record iteration for current configuration
        if let current = currentConfiguration {
            iterationsPerConfig[current.activeCategories, default: 0] += 1
        }

        // Check if we need to resample
        if currentConfiguration == nil ||
           iterationsSinceConfigChange >= config.configurationWindow {
            currentConfiguration = sampleConfiguration()
            iterationsSinceConfigChange = 0
            totalConfigurations += 1
            return true
        }

        return false
    }

    /// Sample a new configuration based on configured probability.
    private func sampleConfiguration() -> SwarmConfiguration {
        let allCategories = Set(MutatorCategory.allCases)

        // Include each category with configured probability
        var selected = allCategories.filter { _ in
            Double.random(in: 0..<1) < config.mutatorInclusionProbability
        }

        // Ensure minimum mutators constraint
        while selected.count < config.minActiveMutators {
            let remaining = allCategories.subtracting(selected)
            if let next = remaining.randomElement() {
                selected.insert(next)
            } else {
                break
            }
        }

        // Ensure maximum mutators constraint if set
        if let maxMutators = config.maxActiveMutators {
            while selected.count > maxMutators {
                if let removed = selected.randomElement() {
                    selected.remove(removed)
                }
            }
        }

        return SwarmConfiguration(activeCategories: selected)
    }

    // MARK: - Category Checking

    /// Check if a mutator category should be applied.
    public func shouldApply(_ category: MutatorCategory) -> Bool {
        guard config.enabled else { return true }
        return currentConfiguration?.isActive(category) ?? true
    }

    /// Get current configuration (if swarm mode enabled).
    public var current: SwarmConfiguration? {
        currentConfiguration
    }

    // MARK: - Statistics Tracking

    /// Record that current configuration discovered new coverage.
    public mutating func recordCoverageHit() {
        guard let current = currentConfiguration else { return }
        coverageHits[current.activeCategories, default: 0] += 1
    }

    /// Statistics about swarm testing effectiveness.
    public var stats: SwarmStats {
        SwarmStats(
            totalConfigurations: totalConfigurations,
            currentConfiguration: currentConfiguration?.activeCategories,
            coverageHitsPerConfig: coverageHits,
            iterationsPerConfig: iterationsPerConfig
        )
    }

    /// Generate a summary string for logging.
    public func summary() -> String {
        guard let current = currentConfiguration else {
            return "swarm=disabled"
        }
        return "swarm=\(current.description)"
    }
}

// MARK: - SwarmStats

/// Statistics about swarm testing effectiveness.
public struct SwarmStats: Sendable {
    /// Total number of distinct configurations tested.
    public let totalConfigurations: Int

    /// Currently active configuration.
    public let currentConfiguration: Set<MutatorCategory>?

    /// Coverage hits per configuration.
    public let coverageHitsPerConfig: [Set<MutatorCategory>: Int]

    /// Iterations per configuration.
    public let iterationsPerConfig: [Set<MutatorCategory>: Int]

    /// Top configurations by coverage hit rate.
    public var topConfigurations: [(config: Set<MutatorCategory>, hitRate: Double)] {
        var results: [(Set<MutatorCategory>, Double)] = []

        for (config, hits) in coverageHitsPerConfig {
            let iterations = iterationsPerConfig[config] ?? 1
            let rate = Double(hits) / Double(iterations)
            results.append((config, rate))
        }

        return results.sorted { $0.1 > $1.1 }
    }

    /// Average coverage hit rate across all configurations.
    public var averageHitRate: Double {
        let totalHits = coverageHitsPerConfig.values.reduce(0, +)
        let totalIterations = iterationsPerConfig.values.reduce(0, +)
        guard totalIterations > 0 else { return 0 }
        return Double(totalHits) / Double(totalIterations)
    }

    /// Generate a report string.
    public func report() -> String {
        var lines: [String] = []
        lines.append("Swarm Testing Statistics:")
        lines.append("  Configurations tested: \(totalConfigurations)")
        lines.append("  Average hit rate: \(String(format: "%.4f", averageHitRate))")

        if !topConfigurations.isEmpty {
            lines.append("  Top configurations:")
            for (config, rate) in topConfigurations.prefix(3) {
                let names = config.map { $0.rawValue }.sorted().joined(separator: ", ")
                lines.append("    [\(names)]: \(String(format: "%.4f", rate))")
            }
        }

        return lines.joined(separator: "\n")
    }
}
