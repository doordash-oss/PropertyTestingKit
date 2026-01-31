//
//  STADSPlateauDetector.swift
//  PropertyTestingKit
//
//  Good-Turing estimator for fuzzing stopping criterion.
//
//  Based on:
//  - Böhme, M. (2018). "STADS: Software Testing as Species Discovery"
//    https://mboehme.github.io/paper/TSE18.pdf
//

import Foundation
import Dependencies

/// Plateau detector using the Good-Turing estimator from STADS (Böhme 2018).
///
/// Uses statistical principles from ecology (species discovery) to estimate
/// the probability of discovering new coverage paths. Stops when this
/// probability drops below a threshold.
///
/// ## Algorithm
///
/// The Good-Turing estimator estimates the probability of discovering a new
/// "species" (unique coverage path) as:
///
/// ```
/// P(new) = n₁ / N
/// ```
///
/// Where:
/// - `n₁` = number of singletons (paths seen exactly once)
/// - `N` = total number of observations (iterations)
///
/// This works because singletons represent "rare" discoveries that suggest
/// there may be more undiscovered paths. As fuzzing progresses, singletons
/// become less common (they're seen again), and P(new) naturally decreases.
///
/// ## Reference
///
/// Böhme, M. (2018). "STADS: Software Testing as Species Discovery"
/// IEEE Transactions on Software Engineering.
///
/// For simpler heuristic approaches, see ``SimpleCoveragePlateauDetector``.
/// For saturation-based metrics, see ``SaturationPlateauDetector``.
public struct STADSPlateauDetector: Sendable {
    @Dependency(\.dateClient) var dateClient

    /// Configuration for STADS plateau detection.
    public struct Config: Sendable {
        /// Minimum discovery probability before declaring plateau.
        /// Default: 0.001 = 0.1% chance of new discovery per iteration
        var minDiscoveryProbability: Double

        /// Number of consecutive checks below threshold required.
        /// Higher values prevent premature stopping.
        var confirmationChecks: Int

        /// How often to recalculate discovery probability.
        /// Default: every 100 iterations
        var checkInterval: Int

        /// Whether STADS detection is enabled.
        var enabled: Bool

        public init(
            minDiscoveryProbability: Double = 0.001,
            confirmationChecks: Int = 3,
            checkInterval: Int = 100,
            enabled: Bool = true
        ) {
            self.minDiscoveryProbability = minDiscoveryProbability
            self.confirmationChecks = confirmationChecks
            self.checkInterval = checkInterval
            self.enabled = enabled
        }
    }

    private let config: Config

    /// Frequency table: signature hash -> observation count
    private var signatureFrequencies: [UInt64: Int] = [:]

    /// Count of singletons (signatures seen exactly once)
    private var singletonCount: Int = 0

    /// Total observations (iterations with coverage data)
    private var totalObservations: Int = 0

    /// Total unique signatures discovered
    private var totalDiscoveries: Int = 0

    /// Iterations since last check
    private var iterationsSinceCheck: Int = 0

    /// Number of consecutive low-probability checks
    private var lowProbabilityChecks: Int = 0

    /// Current estimated discovery probability
    private var currentProbability: Double = 1.0

    /// Time when first observation was recorded
    private var startTime: Date?

    init(config: Config = Config()) {
        self.config = config
    }

    /// Record an observation with a coverage signature.
    ///
    /// - Parameter signatureHash: Hash of the coverage signature for this iteration.
    ///   Use 0 or nil to indicate no new coverage (same as previous).
    mutating func record(signatureHash: UInt64) {
        if startTime == nil {
            startTime = dateClient.now()
        }

        totalObservations += 1
        iterationsSinceCheck += 1

        if signatureHash != 0 {
            let previousCount = signatureFrequencies[signatureHash] ?? 0
            signatureFrequencies[signatureHash] = previousCount + 1

            if previousCount == 0 {
                // New discovery - it's now a singleton
                singletonCount += 1
                totalDiscoveries += 1
            } else if previousCount == 1 {
                // Was a singleton, now seen twice - no longer a singleton
                singletonCount -= 1
            }
        }

        // Periodic probability recalculation
        if iterationsSinceCheck >= config.checkInterval {
            recalculateProbability()
            iterationsSinceCheck = 0
        }
    }

    /// Record whether this iteration discovered new coverage.
    ///
    /// Convenience method when you don't have a signature hash.
    /// Uses a simple counter-based approach instead of tracking signatures.
    ///
    /// Note: Without actual signature hashes, this approximates singleton tracking
    /// by treating all discoveries as singletons and decaying them periodically
    /// based on the discovery rate. For accurate Good-Turing estimation, use
    /// `record(signatureHash:)` instead.
    mutating func record(discoveredNewCoverage: Bool) {
        if startTime == nil {
            startTime = dateClient.now()
        }

        totalObservations += 1
        iterationsSinceCheck += 1

        if discoveredNewCoverage {
            totalDiscoveries += 1
            // Approximate singleton tracking: new discoveries are singletons
            singletonCount += 1
        }

        if iterationsSinceCheck >= config.checkInterval {
            // Decay singletons based on discovery rate at check time
            // This approximates the effect of re-seeing signatures
            let discoveriesInWindow = totalDiscoveries > 0 ?
                Double(min(iterationsSinceCheck, totalDiscoveries)) / Double(iterationsSinceCheck) : 0

            // Only decay if discovery rate is low (meaning we're re-hitting paths)
            if discoveriesInWindow < 0.1 && singletonCount > 0 {
                // Conservative decay: assume half of singletons are no longer unique
                singletonCount = max(0, singletonCount / 2)
            }

            recalculateProbability()
            iterationsSinceCheck = 0
        }
    }

    private mutating func recalculateProbability() {
        guard totalObservations > 0 else {
            currentProbability = 1.0
            return
        }

        // Good-Turing estimator: P(new) = n₁ / N
        currentProbability = Double(singletonCount) / Double(totalObservations)

        if currentProbability < config.minDiscoveryProbability {
            lowProbabilityChecks += 1
        } else {
            lowProbabilityChecks = 0
        }
    }

    /// Check if coverage has plateaued based on Good-Turing estimate.
    var hasPlateaued: Bool {
        guard config.enabled else { return false }
        guard totalObservations >= config.checkInterval else { return false }

        return lowProbabilityChecks >= config.confirmationChecks
    }

    /// Current estimated probability of discovering new coverage.
    var discoveryProbability: Double {
        currentProbability
    }

    /// Number of unique coverage paths discovered.
    var uniquePathsDiscovered: Int {
        totalDiscoveries
    }

    /// Statistics about the STADS detector state.
    func stats() -> STADSPlateauStats {
        let now = dateClient.now()
        return STADSPlateauStats(
            totalObservations: totalObservations,
            totalDiscoveries: totalDiscoveries,
            singletonCount: singletonCount,
            discoveryProbability: currentProbability,
            lowProbabilityChecks: lowProbabilityChecks,
            hasPlateaued: hasPlateaued,
            duration: startTime.map { now.timeIntervalSince($0) } ?? 0
        )
    }

    /// Generate a summary string for logging.
    func summary(includeDetails: Bool = false) -> String {
        let stats = self.stats()

        var parts: [String] = []

        if hasPlateaued {
            parts.append("STADS plateau detected")
        }

        parts.append(String(format: "P(new)=%.4f", stats.discoveryProbability))
        parts.append("discoveries=\(stats.totalDiscoveries)")

        if includeDetails {
            parts.append("singletons=\(stats.singletonCount)")
            parts.append("low_checks=\(stats.lowProbabilityChecks)")
        }

        return parts.joined(separator: ", ")
    }
}

/// Statistics from the STADS plateau detector.
struct STADSPlateauStats: Sendable {
    /// Total iterations observed.
    let totalObservations: Int

    /// Total unique coverage paths discovered.
    let totalDiscoveries: Int

    /// Number of singletons (paths seen exactly once).
    let singletonCount: Int

    /// Estimated probability of discovering new coverage.
    let discoveryProbability: Double

    /// Number of consecutive low-probability checks.
    let lowProbabilityChecks: Int

    /// Whether plateau has been detected.
    let hasPlateaued: Bool

    /// Time elapsed since first observation.
    let duration: TimeInterval

    /// Discoveries per second.
    var discoveriesPerSecond: Double {
        duration > 0 ? Double(totalDiscoveries) / duration : 0
    }
}
