//
//  RareBranchTracker.swift
//  PropertyTestingKit
//
//  FairFuzz-inspired rare branch tracking and targeting.
//
//  Based on:
//  - Lemieux & Sen (2018) "FairFuzz: A Targeted Mutation Strategy for
//    Increasing Greybox Fuzz Testing Coverage"
//
//  The key insight is that traditional fuzzers allocate effort uniformly
//  across all discovered branches, creating imbalance where frequently-
//  executed branches receive most attention while rarely-hit branches
//  (which often guard complex logic and vulnerabilities) are underexplored.
//

import Foundation

// MARK: - RareBranchTracker

/// Tracks which coverage branches are rarely hit across the corpus.
///
/// Uses FairFuzz's power-of-two threshold: if the least-covered branch
/// is hit by N inputs, any branch hit by ≤ next_power_of_two(N) inputs
/// is classified as "rare".
///
/// ## Algorithm
///
/// 1. Track hit counts: how many corpus entries exercise each branch
/// 2. Compute threshold: smallest power of two ≥ minimum hit count
/// 3. Classify branches: those with hit count ≤ threshold are rare
/// 4. Report rare indices for use in seed selection
///
/// ## Usage
///
/// ```swift
/// var tracker = RareBranchTracker()
///
/// // Update after corpus changes
/// tracker.update(from: corpus.signatures)
///
/// // Get rare branch indices for selection
/// let rareIndices = tracker.rareIndices
///
/// // Prefer seeds hitting rare branches
/// if let selectedIndex = corpus.selectForMutation(preferring: rareIndices) {
///     // Mutate the selected seed
/// }
/// ```
public struct RareBranchTracker: Sendable {
    /// Configuration for rare branch tracking.
    public struct Config: Sendable {
        /// Whether to use power-of-two threshold (true) or fixed threshold (false).
        public var useDynamicThreshold: Bool

        /// Fixed threshold when not using dynamic (branch is rare if hit count ≤ this).
        /// Only used when `useDynamicThreshold` is false.
        public var fixedThreshold: Int

        /// Minimum threshold even for dynamic calculation.
        /// Prevents all branches from being classified as rare early in fuzzing.
        public var minimumThreshold: Int

        /// Whether rare branch tracking is enabled.
        public var enabled: Bool

        public init(
            useDynamicThreshold: Bool = true,
            fixedThreshold: Int = 5,
            minimumThreshold: Int = 2,
            enabled: Bool = true
        ) {
            self.useDynamicThreshold = useDynamicThreshold
            self.fixedThreshold = fixedThreshold
            self.minimumThreshold = minimumThreshold
            self.enabled = enabled
        }
    }

    private let config: Config

    /// Maps coverage index -> number of corpus entries hitting it.
    private var indexHitCounts: [Int: Int] = [:]

    /// Current rarity threshold.
    private var currentThreshold: Int = 1

    /// Cached set of rare indices (updated when threshold changes).
    private var _rareIndices: Set<Int> = []

    /// Total branches tracked.
    private var totalBranches: Int = 0

    public init(config: Config = Config()) {
        self.config = config
    }

    // MARK: - Update

    /// Update hit counts from corpus signatures.
    ///
    /// Call this after corpus additions or periodically during fuzzing.
    ///
    /// - Parameter signatures: All coverage signatures from the corpus.
    public mutating func update(from signatures: [CoverageSignature]) {
        guard config.enabled else { return }

        // Reset and recompute
        indexHitCounts.removeAll(keepingCapacity: true)

        for signature in signatures {
            for index in signature.executedIndices {
                indexHitCounts[index, default: 0] += 1
            }
        }

        totalBranches = indexHitCounts.count
        currentThreshold = computeThreshold()
        updateRareIndices()
    }

    /// Incrementally update when a new entry is added.
    ///
    /// More efficient than full update for single additions.
    ///
    /// - Parameter signature: The new entry's coverage signature.
    public mutating func recordEntry(_ signature: CoverageSignature) {
        guard config.enabled else { return }

        for index in signature.executedIndices {
            indexHitCounts[index, default: 0] += 1
        }

        totalBranches = indexHitCounts.count

        // Periodically recompute threshold (every 100 additions for efficiency)
        // The threshold changes slowly so we don't need to recompute every time
    }

    /// Force threshold recomputation and rare indices update.
    public mutating func recomputeThreshold() {
        currentThreshold = computeThreshold()
        updateRareIndices()
    }

    // MARK: - Threshold Computation

    /// Compute FairFuzz power-of-two threshold.
    ///
    /// The threshold is the smallest power of two ≥ minimum hit count.
    private func computeThreshold() -> Int {
        if !config.useDynamicThreshold {
            return config.fixedThreshold
        }

        guard let minHits = indexHitCounts.values.min(), minHits > 0 else {
            return config.minimumThreshold
        }

        // Next power of two ≥ minHits
        var threshold = 1
        while threshold < minHits {
            threshold *= 2
        }

        return max(threshold, config.minimumThreshold)
    }

    /// Update the cached rare indices set.
    private mutating func updateRareIndices() {
        _rareIndices = Set(
            indexHitCounts
                .filter { $0.value <= currentThreshold }
                .keys
        )
    }

    // MARK: - Query

    /// Set of rare branch indices (hit count ≤ threshold).
    public var rareIndices: Set<Int> {
        _rareIndices
    }

    /// Number of rare branches.
    public var rareCount: Int {
        _rareIndices.count
    }

    /// Current rarity threshold.
    public var threshold: Int {
        currentThreshold
    }

    /// Check if a specific index is rare.
    public func isRare(_ index: Int) -> Bool {
        _rareIndices.contains(index)
    }

    /// Count how many rare branches a signature hits.
    public func rareHitCount(for signature: CoverageSignature) -> Int {
        signature.executedIndices.intersection(_rareIndices).count
    }

    /// Get the rarest branch index from a signature (lowest hit count).
    public func rarestBranch(in signature: CoverageSignature) -> Int? {
        let rareHits = signature.executedIndices.intersection(_rareIndices)
        return rareHits.min { indexHitCounts[$0, default: 0] < indexHitCounts[$1, default: 0] }
    }

    // MARK: - Statistics

    /// Statistics about rare branch tracking.
    public var stats: RareBranchStats {
        RareBranchStats(
            totalBranches: totalBranches,
            rareBranches: _rareIndices.count,
            threshold: currentThreshold,
            minHitCount: indexHitCounts.values.min() ?? 0,
            maxHitCount: indexHitCounts.values.max() ?? 0,
            averageHitCount: totalBranches > 0
                ? Double(indexHitCounts.values.reduce(0, +)) / Double(totalBranches)
                : 0
        )
    }

    /// Generate a summary string for logging.
    public func summary() -> String {
        let stats = self.stats
        let pctRare = stats.totalBranches > 0
            ? Double(stats.rareBranches) / Double(stats.totalBranches) * 100
            : 0
        return String(format: "rare=%d/%d (%.1f%%), threshold=%d",
                      stats.rareBranches, stats.totalBranches, pctRare, stats.threshold)
    }
}

/// Statistics about rare branch tracking.
public struct RareBranchStats: Sendable {
    /// Total number of unique branches discovered.
    public let totalBranches: Int

    /// Number of branches classified as rare.
    public let rareBranches: Int

    /// Current rarity threshold.
    public let threshold: Int

    /// Minimum hit count across all branches.
    public let minHitCount: Int

    /// Maximum hit count across all branches.
    public let maxHitCount: Int

    /// Average hit count across all branches.
    public let averageHitCount: Double

    /// Percentage of branches that are rare.
    public var rarePercentage: Double {
        totalBranches > 0 ? Double(rareBranches) / Double(totalBranches) * 100 : 0
    }

    /// Gini coefficient measuring coverage inequality (0 = perfect equality, 1 = maximum inequality).
    /// Lower values indicate more uniform coverage distribution.
    public var coverageGini: Double {
        // Would need full hit count distribution to compute properly
        // This is a placeholder - actual implementation would sort hit counts and compute
        0
    }
}

// MARK: - Corpus Extension

extension Corpus {
    /// Select an entry for mutation, preferring entries that hit rare branches.
    ///
    /// Uses FairFuzz-style selection: with probability `rareBranchProbability`,
    /// select from entries hitting rare branches. Otherwise, use standard selection.
    ///
    /// - Parameters:
    ///   - rareIndices: Set of rare branch indices to target.
    ///   - rareBranchProbability: Probability of selecting a rare-branch entry (0-1).
    /// - Returns: Index of selected entry, or nil if corpus is empty.
    public mutating func selectForMutation(
        preferring rareIndices: Set<Int>,
        probability rareBranchProbability: Double = 0.8
    ) -> Int? {
        guard !entries.isEmpty else { return nil }

        // Decide whether to use rare branch selection
        if !rareIndices.isEmpty && Double.random(in: 0..<1) < rareBranchProbability {
            // Find entries hitting rare branches and score them
            var candidates: [(index: Int, score: Double)] = []

            for (idx, entry) in entries.enumerated() {
                let rareHits = entry.signature.executedIndices.intersection(rareIndices)
                if !rareHits.isEmpty {
                    // Score by number of rare branches hit
                    // This naturally prefers entries covering more rare branches
                    candidates.append((idx, Double(rareHits.count)))
                }
            }

            if !candidates.isEmpty {
                // Weighted random selection among rare-branch-hitting entries
                let totalScore = candidates.reduce(0.0) { $0 + $1.score }
                guard totalScore > 0 else { return candidates.randomElement()?.index }

                var random = Double.random(in: 0..<totalScore)
                for (idx, score) in candidates.dropLast() {
                    random -= score
                    if random <= 0 { return idx }
                }
                return candidates.last?.index
            }
            // Fall through to standard selection if no rare branch hits
        }

        // Standard selection (either by choice or fallback)
        return selectForMutation()
    }
}
