//
//  CoverageSignature.swift
//  PropertyTestingKit
//
//  A stable representation of code coverage for comparing test inputs.
//

import Foundation

// MARK: - CoverageSignature

/// A stable representation of coverage state that can be compared across runs.
///
/// Unlike raw counters, signatures use bucketed execution counts to remain
/// stable despite minor variations in loop iterations or non-determinism.
/// This follows AFL's approach: counters are bucketed into categories
/// (0, 1, 2, 3, 4-7, 8-15, 16-31, 32-127, 128+).
///
/// Two inputs with the same signature exercised the same code paths in
/// roughly the same way. Different signatures indicate different coverage.
public struct CoverageSignature: Hashable, Codable, Sendable {
    /// Bucketed counter values, keyed by counter index.
    /// Only non-zero buckets are stored for efficiency.
    public let buckets: [Int: Bucket]

    /// The bucket categories, following AFL's approach.
    public enum Bucket: UInt8, Codable, Sendable {
        case zero = 0
        case one = 1
        case two = 2
        case three = 3
        case fourToSeven = 4
        case eightToFifteen = 5
        case sixteenToThirtyOne = 6
        case thirtyTwoTo127 = 7
        case oneHundredTwentyEightPlus = 8

        /// Create a bucket from a raw counter value.
        public init(count: UInt64) {
            switch count {
            case 0: self = .zero
            case 1: self = .one
            case 2: self = .two
            case 3: self = .three
            case 4...7: self = .fourToSeven
            case 8...15: self = .eightToFifteen
            case 16...31: self = .sixteenToThirtyOne
            case 32...127: self = .thirtyTwoTo127
            default: self = .oneHundredTwentyEightPlus
            }
        }
    }

    /// Create a signature from raw counter values.
    public init(counters: [UInt64]) {
        var buckets: [Int: Bucket] = [:]
        for (index, count) in counters.enumerated() {
            let bucket = Bucket(count: count)
            if bucket != .zero {
                buckets[index] = bucket
            }
        }
        self.buckets = buckets
    }

    /// Create a signature from a CounterDiff (delta counters).
    public init(diff: CounterDiff) {
        var buckets: [Int: Bucket] = [:]

        // Use the delta values, not absolute values
        let beforeCounters = diff.before.counters
        let afterCounters = diff.after.counters
        let maxCount = max(beforeCounters.count, afterCounters.count)

        for i in 0..<maxCount {
            let before = i < beforeCounters.count ? beforeCounters[i] : 0
            let after = i < afterCounters.count ? afterCounters[i] : 0
            let delta = after >= before ? after - before : 0

            let bucket = Bucket(count: delta)
            if bucket != .zero {
                buckets[i] = bucket
            }
        }
        self.buckets = buckets
    }

    /// Create a signature from a CoverageCounters snapshot.
    public init(snapshot: CoverageCounters) {
        self.init(counters: snapshot.counters)
    }

    /// Create directly from buckets (for testing/deserialization).
    public init(buckets: [Int: Bucket]) {
        self.buckets = buckets
    }

    /// Number of counter regions that were executed.
    public var executedCount: Int {
        buckets.count
    }

    /// Whether this signature represents any coverage at all.
    public var isEmpty: Bool {
        buckets.isEmpty
    }

    /// The set of counter indices that were executed.
    public var executedIndices: Set<Int> {
        Set(buckets.keys)
    }

    // MARK: - Comparison

    /// Returns the indices covered by this signature but not the other.
    public func uniqueIndices(comparedTo other: CoverageSignature) -> Set<Int> {
        executedIndices.subtracting(other.executedIndices)
    }

    /// Returns the indices covered by both signatures.
    public func commonIndices(with other: CoverageSignature) -> Set<Int> {
        executedIndices.intersection(other.executedIndices)
    }

    /// Returns whether this signature covers any indices not in the other.
    public func hasUniqueCoverage(comparedTo other: CoverageSignature) -> Bool {
        !uniqueIndices(comparedTo: other).isEmpty
    }

    /// Returns the union of this signature with another.
    /// Takes the maximum bucket value for each index.
    public func union(with other: CoverageSignature) -> CoverageSignature {
        var merged = buckets
        for (index, bucket) in other.buckets {
            if let existing = merged[index] {
                merged[index] = max(existing, bucket)
            } else {
                merged[index] = bucket
            }
        }
        return CoverageSignature(buckets: merged)
    }
}

// MARK: - Bucket Comparable

extension CoverageSignature.Bucket: Comparable {
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - CustomStringConvertible

extension CoverageSignature: CustomStringConvertible {
    public var description: String {
        "CoverageSignature(\(executedCount) regions)"
    }
}

extension CoverageSignature.Bucket: CustomStringConvertible {
    public var description: String {
        switch self {
        case .zero: return "0"
        case .one: return "1"
        case .two: return "2"
        case .three: return "3"
        case .fourToSeven: return "4-7"
        case .eightToFifteen: return "8-15"
        case .sixteenToThirtyOne: return "16-31"
        case .thirtyTwoTo127: return "32-127"
        case .oneHundredTwentyEightPlus: return "128+"
        }
    }
}

// MARK: - Signature Collection

/// A collection of coverage signatures with utilities for analysis.
public struct SignatureSet: Codable, Sendable {
    /// All unique signatures seen.
    public private(set) var signatures: Set<CoverageSignature>

    /// The union of all coverage (all indices ever executed).
    public private(set) var totalCoverage: CoverageSignature

    public init() {
        self.signatures = []
        self.totalCoverage = CoverageSignature(buckets: [:])
    }

    /// Add a signature to the set.
    /// Returns true if this signature was new (not seen before).
    @discardableResult
    public mutating func insert(_ signature: CoverageSignature) -> Bool {
        let isNew = signatures.insert(signature).inserted
        totalCoverage = totalCoverage.union(with: signature)
        return isNew
    }

    /// Check if a signature would add new coverage.
    public func wouldAddNewCoverage(_ signature: CoverageSignature) -> Bool {
        signature.hasUniqueCoverage(comparedTo: totalCoverage)
    }

    /// Number of unique signatures.
    public var count: Int {
        signatures.count
    }

    /// Total number of unique counter indices covered.
    public var totalCoveredIndices: Int {
        totalCoverage.executedCount
    }
}
