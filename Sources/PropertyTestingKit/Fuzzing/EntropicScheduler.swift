//
//  EntropicScheduler.swift
//  PropertyTestingKit
//
//  Entropic seed selection using Shannon entropy for corpus prioritization.
//
//  Based on:
//  - Böhme, Manès, & Cha (2020) "Boosting Fuzzer Efficiency: An Information
//    Theoretic Perspective" - ACM SIGSOFT Distinguished Paper Award
//
//  The key insight is to frame fuzzing as a learning process viewed through
//  information theory: inputs that exercise globally rare features provide
//  more information than inputs exercising common features.
//

import Foundation

// MARK: - Feature

/// A feature is a (coverage index, hit-count bucket) pair.
///
/// This is more fine-grained than simple edge coverage - an edge executed
/// 1 time vs 100 times represents different features.
public struct Feature: Hashable, Sendable {
    /// The coverage counter index.
    public let index: Int

    /// The hit-count bucket for this execution.
    public let bucket: CoverageSignature.Bucket
}

// MARK: - EntropicScheduler

/// Shannon entropy-based seed selection scheduler.
///
/// Entropic assigns higher mutation energy to seeds revealing more information
/// about rare program features. Seeds exercising features with low global
/// frequency receive higher priority for mutation.
///
/// ## Algorithm
///
/// 1. Track global feature frequencies across the entire corpus
/// 2. Identify "rare features" (frequency below threshold)
/// 3. Compute Shannon entropy for each seed based on its rare features
/// 4. Sample seeds proportionally to their entropy (higher entropy = more likely)
///
/// ## Performance
///
/// In LibFuzzer's evaluation, Entropic achieved the same coverage as baseline
/// in less than half the time for most subjects (1.63x improvement on average).
public struct EntropicScheduler: Sendable {
    /// Configuration for the entropic scheduler.
    public struct Config: Sendable {
        /// Abundance threshold for rare feature detection.
        /// Features observed less than this many times are considered "rare".
        /// Default: 0xFF (255) matches LibFuzzer's implementation.
        public var abundanceThreshold: UInt16

        /// Minimum entropy value to prevent starvation.
        /// Seeds always have at least this weight for selection.
        public var minimumEntropy: Double

        /// Whether entropic scheduling is enabled.
        public var enabled: Bool

        public init(
            abundanceThreshold: UInt16 = 0xFF,
            minimumEntropy: Double = 0.1,
            enabled: Bool = true
        ) {
            self.abundanceThreshold = abundanceThreshold
            self.minimumEntropy = minimumEntropy
            self.enabled = enabled
        }
    }

    private let config: Config

    /// Global feature frequency across all corpus entries.
    /// Key: Feature (index, bucket pair)
    /// Value: Saturating 16-bit count of how many seeds exercise this feature
    private var globalFeatureFrequency: [Feature: UInt16] = [:]

    /// Cached entropy values for each corpus entry (by index).
    private var entropies: [Double] = []

    /// Set of rare features (frequency < threshold).
    private var rareFeatures: Set<Feature> = []

    /// Number of corpus additions since last entropy recomputation.
    private var additionsSinceUpdate: Int = 0

    /// How often to recompute all entropies (batch updates for efficiency).
    private let recomputeInterval: Int = 100

    public init(config: Config = Config()) {
        self.config = config
    }

    // MARK: - Feature Tracking

    /// Extract features from a coverage signature.
    public static func extractFeatures(from signature: CoverageSignature) -> [Feature] {
        signature.buckets.map { Feature(index: $0.key, bucket: $0.value) }
    }

    /// Update global feature frequencies when a new entry is added.
    ///
    /// - Parameter signature: The coverage signature of the new entry.
    public mutating func recordEntry(_ signature: CoverageSignature) {
        guard config.enabled else { return }

        let features = Self.extractFeatures(from: signature)

        // Update global frequencies (saturating increment)
        for feature in features {
            let current = globalFeatureFrequency[feature] ?? 0
            globalFeatureFrequency[feature] = min(current &+ 1, UInt16.max)
        }

        // Assign initial maximum entropy to new entry
        let initialEntropy = log2(Double(max(rareFeatures.count, 1)))
        entropies.append(max(initialEntropy, config.minimumEntropy))

        additionsSinceUpdate += 1

        // Periodically recompute all entropies for accuracy
        if additionsSinceUpdate >= recomputeInterval {
            recomputeAllEntropies()
            additionsSinceUpdate = 0
        }
    }

    /// Recompute entropy for all entries based on current global frequencies.
    private mutating func recomputeAllEntropies() {
        // Update rare features set
        rareFeatures = Set(
            globalFeatureFrequency
                .filter { $0.value < config.abundanceThreshold }
                .keys
        )

        // Note: Full recomputation requires access to all signatures.
        // This is called from Corpus which will provide the signatures.
    }

    /// Compute entropy for a single signature given current global state.
    ///
    /// Uses Shannon entropy formula: H = -Σ(p_i * log2(p_i))
    /// with add-one smoothing to handle zero frequencies.
    public func computeEntropy(for signature: CoverageSignature) -> Double {
        guard config.enabled else { return 1.0 }

        let features = Self.extractFeatures(from: signature)

        // Filter to only rare features for efficiency
        let relevantFeatures = features.filter { rareFeatures.contains($0) }
        guard !relevantFeatures.isEmpty else { return config.minimumEntropy }

        // Compute local feature frequencies for this signature
        var localFrequency: [Feature: UInt32] = [:]
        for feature in relevantFeatures {
            localFrequency[feature, default: 0] += 1
        }

        // Add-one smoothing: count each feature as appearing at least once
        var sumIncidence: UInt32 = 0
        for feature in relevantFeatures {
            let count = localFrequency[feature] ?? 0
            sumIncidence += count + 1  // Add-one smoothing
        }

        guard sumIncidence > 0 else { return config.minimumEntropy }

        // Shannon entropy: -Σ(p_i * log2(p_i))
        var entropy: Double = 0.0
        for feature in relevantFeatures {
            let count = localFrequency[feature] ?? 0
            let smoothedCount = Double(count + 1)  // Add-one smoothing
            let probability = smoothedCount / Double(sumIncidence)
            if probability > 0 {
                entropy -= probability * log2(probability)
            }
        }

        // Add log2(sumIncidence) for normalization (matches LibFuzzer)
        entropy += log2(Double(sumIncidence))

        return max(entropy, config.minimumEntropy)
    }

    // MARK: - Selection

    /// Select an entry index for mutation using entropy-weighted sampling.
    ///
    /// Higher entropy entries (exercising rare features) are more likely to be selected.
    ///
    /// - Parameter signatures: All corpus entry signatures.
    /// - Returns: Index of the selected entry, or nil if empty.
    public func selectForMutation(signatures: [CoverageSignature]) -> Int? {
        guard !signatures.isEmpty else { return nil }

        if !config.enabled {
            // Fallback to uniform random selection
            return signatures.indices.randomElement()
        }

        // Compute entropy weights for all entries
        let weights: [Double]
        if entropies.count == signatures.count {
            weights = entropies
        } else {
            // Recompute if out of sync
            weights = signatures.map { computeEntropy(for: $0) }
        }

        let totalWeight = weights.reduce(0, +)
        guard totalWeight > 0 else { return signatures.indices.randomElement() }

        // Weighted random selection
        var random = Double.random(in: 0..<totalWeight)
        for (i, weight) in weights.dropLast().enumerated() {
            random -= weight
            if random <= 0 {
                return i
            }
        }

        return weights.count - 1
    }

    /// Update entropy for a specific entry (e.g., after recomputation).
    public mutating func updateEntropy(at index: Int, value: Double) {
        guard index < entropies.count else { return }
        entropies[index] = max(value, config.minimumEntropy)
    }

    /// Full recomputation of all entropies.
    ///
    /// Called periodically from Corpus to maintain accuracy.
    public mutating func recomputeEntropies(for signatures: [CoverageSignature]) {
        // Update rare features set
        rareFeatures = Set(
            globalFeatureFrequency
                .filter { $0.value < config.abundanceThreshold }
                .keys
        )

        // Recompute entropy for each entry
        entropies = signatures.map { computeEntropy(for: $0) }
    }

    // MARK: - Statistics

    /// Current statistics about the entropic scheduler.
    public var stats: EntropicStats {
        EntropicStats(
            totalFeatures: globalFeatureFrequency.count,
            rareFeatures: rareFeatures.count,
            averageEntropy: entropies.isEmpty ? 0 : entropies.reduce(0, +) / Double(entropies.count),
            maxEntropy: entropies.max() ?? 0,
            minEntropy: entropies.min() ?? 0
        )
    }
}

/// Statistics about the entropic scheduler.
public struct EntropicStats: Sendable {
    /// Total number of unique features tracked.
    public let totalFeatures: Int

    /// Number of features considered "rare".
    public let rareFeatures: Int

    /// Average entropy across all corpus entries.
    public let averageEntropy: Double

    /// Maximum entropy among corpus entries.
    public let maxEntropy: Double

    /// Minimum entropy among corpus entries.
    public let minEntropy: Double
}
