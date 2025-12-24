//
//  ValueProfile.swift
//  PropertyTestingKit
//
//  Swift interface for value profile guidance.
//  Tracks comparison operand distances to guide fuzzing toward magic values.
//

import Foundation
import ValueProfileHooks

// MARK: - Comparison Record

/// A Swift representation of a captured comparison.
public struct ComparisonRecord: Hashable, Sendable {
    /// Program counter identifying the comparison location.
    public let location: UInt64

    /// First operand of the comparison.
    public let arg1: UInt64

    /// Second operand of the comparison.
    public let arg2: UInt64

    /// Absolute distance between operands.
    public let distance: UInt64

    /// Size of the comparison in bytes (1, 2, 4, or 8).
    public let size: UInt8

    /// Whether one operand was a compile-time constant.
    public let isConstant: Bool

    /// Bucketed distance for efficient storage.
    /// Uses AFL-style bucketing to reduce noise.
    public var bucketedDistance: UInt8 {
        switch distance {
        case 0: return 0
        case 1: return 1
        case 2: return 2
        case 3: return 3
        case 4...7: return 4
        case 8...15: return 5
        case 16...31: return 6
        case 32...127: return 7
        default: return 8
        }
    }
}

// MARK: - Value Profile Tracker

/// Tracks comparison distances across test executions.
///
/// Used for value profile guidance: inputs that get "closer" to satisfying
/// comparisons are prioritized for further mutation.
public actor ValueProfileTracker {
    /// Key for tracking minimum distances.
    private struct LocationKey: Hashable, Sendable {
        let pc: UInt64
        let constantValue: UInt64
    }

    /// Minimum distance seen for each (location, constant) pair.
    private var minimumDistances: [LocationKey: UInt64] = [:]

    public init() {}

    /// Enable comparison recording.
    nonisolated public func enable() {
        vp_set_enabled(true)
    }

    /// Disable comparison recording.
    nonisolated public func disable() {
        vp_set_enabled(false)
    }

    /// Reset the comparison log. Call before each test execution.
    nonisolated public func reset() {
        vp_reset()
    }

    /// Process comparisons from the last test execution.
    ///
    /// - Returns: Array of comparisons that made progress (got closer to their target).
    public func processComparisons(debug: Bool = false) -> [ComparisonRecord] {
        let count = vp_get_count()
        guard count > 0, let records = vp_get_records() else {
            return []
        }

        var improvements: [ComparisonRecord] = []

        for i in 0..<count {
            let record = records[i]

            let swiftRecord = ComparisonRecord(
                location: record.pc,
                arg1: record.arg1,
                arg2: record.arg2,
                distance: record.distance,
                size: record.size,
                isConstant: record.is_const
            )

            if debug && record.is_const {
                print("[VP Debug] const cmp: arg1=\(record.arg1), arg2=\(record.arg2), distance=\(record.distance), size=\(record.size)")
            }

            // For constant comparisons, track progress toward the constant
            if record.is_const {
                let key = LocationKey(pc: record.pc, constantValue: record.arg1)
                let previousMin = minimumDistances[key] ?? UInt64.max

                if record.distance < previousMin {
                    minimumDistances[key] = record.distance
                    improvements.append(swiftRecord)
                    if debug {
                        print("[VP Debug] IMPROVEMENT: arg1=\(record.arg1) -> distance \(previousMin) -> \(record.distance)")
                    }
                }
            }
        }

        return improvements
    }

    /// Get statistics about tracked comparisons.
    public func stats() -> (trackedLocations: Int, solvedComparisons: Int) {
        let tracked = minimumDistances.count
        let solved = minimumDistances.values.filter { $0 == 0 }.count
        return (tracked, solved)
    }

    /// Clear all tracking state.
    public func clearState() {
        minimumDistances.removeAll()
        vp_reset()
    }

    /// Debug: dump all comparisons from the last test execution.
    nonisolated public static func dumpComparisons() {
        let count = vp_get_count()
        print("[VP Dump] \(count) comparisons recorded")
        guard count > 0, let records = vp_get_records() else {
            return
        }

        for i in 0..<min(count, 20) {  // Limit to first 20
            let r = records[i]
            let constStr = r.is_const ? "CONST" : "var"
            print("[VP Dump] [\(i)] \(constStr) cmp\(r.size): arg1=\(r.arg1), arg2=\(r.arg2), distance=\(r.distance)")
        }
        if count > 20 {
            print("[VP Dump] ... and \(count - 20) more")
        }
    }
}

// MARK: - Scoring Helpers

extension ValueProfileTracker {
    /// Calculate a score bonus for comparison progress.
    ///
    /// Inputs that get closer to satisfying comparisons receive higher scores.
    /// Uses logarithmic scaling so distance 1 is much better than distance 1000.
    ///
    /// - Parameter improvements: Comparisons that made progress.
    /// - Returns: Score bonus to add to corpus entry.
    public func scoreBonus(for improvements: [ComparisonRecord]) -> Double {
        guard !improvements.isEmpty else { return 0 }

        var bonus = 0.0
        for record in improvements {
            // Logarithmic scoring: smaller distances are exponentially better
            // distance 0: bonus = 10.0
            // distance 1: bonus = 5.0
            // distance 7: bonus = 3.3
            // distance 1000: bonus = 1.0
            let distanceScore = 10.0 / (1.0 + log2(Double(record.distance + 1)))

            // Constant comparisons (magic numbers) are more valuable
            if record.isConstant {
                bonus += distanceScore * 2.0
            } else {
                bonus += distanceScore
            }
        }

        return bonus
    }
}

// MARK: - Target-Directed Mutations

extension ValueProfileTracker {
    /// Represents a comparison target we're trying to reach.
    public struct ComparisonTarget: Hashable, Sendable {
        /// The constant value we're comparing against.
        public let target: UInt64
        /// The current input value.
        public let current: UInt64
        /// Whether this is a signed comparison (affects binary search direction).
        public let isSigned: Bool

        /// Generate binary search mutations toward the target.
        ///
        /// Returns values that progressively narrow the gap between current and target.
        public func binarySearchMutations() -> [Int] {
            var mutations: [Int] = []

            // Always try the target directly if it fits in Int
            if let targetInt = Int(exactly: target) {
                mutations.append(targetInt)

                // Try target ± small offsets (in case of off-by-one issues)
                if targetInt > Int.min { mutations.append(targetInt - 1) }
                if targetInt < Int.max { mutations.append(targetInt + 1) }
            }

            // Only do binary search if both values fit in Int
            guard let currentInt = Int(exactly: current),
                  let targetInt = Int(exactly: target) else {
                return mutations
            }

            // Binary search: try midpoint between current and target
            // Use overflow-safe calculation: a/2 + b/2 + (a%2 + b%2)/2
            let midpoint = currentInt / 2 + targetInt / 2
            if midpoint != currentInt && midpoint != targetInt {
                mutations.append(midpoint)
            }

            // Also try quarter points for faster convergence (with overflow checks)
            // quarterToTarget = current/4 + target*3/4
            let currentQuarter = currentInt / 4
            let targetThreeQuarters = targetInt / 4 * 3  // Reorder to avoid overflow
            let (quarterSum, overflow1) = currentQuarter.addingReportingOverflow(targetThreeQuarters)
            if !overflow1 && quarterSum != midpoint {
                mutations.append(quarterSum)
            }

            // threeQuarterToTarget = current*3/4 + target/4
            let currentThreeQuarters = currentInt / 4 * 3
            let targetQuarter = targetInt / 4
            let (threeQuarterSum, overflow2) = currentThreeQuarters.addingReportingOverflow(targetQuarter)
            if !overflow2 && threeQuarterSum != midpoint {
                mutations.append(threeQuarterSum)
            }

            return Array(Set(mutations)) // Deduplicate
        }

        /// Generate mutations assuming the target might be a modulo result.
        ///
        /// For constraints like `(a + b) % 1000 == 777`, the comparison captures
        /// `result == 777`. This generates values that could satisfy such constraints.
        public func moduloAwareMutations() -> [Int] {
            guard let targetInt = Int(exactly: target) else { return [] }

            // Only apply to small targets that look like modulo results
            guard targetInt >= 0 && targetInt < 100_000 else { return [] }

            var mutations: [Int] = []

            // Common moduli in real code
            let commonModuli = [10, 100, 256, 1000, 1024, 10000, 65536, 100000]

            for modulus in commonModuli {
                // Skip if target >= modulus (can't be result of % modulus)
                guard targetInt < modulus else { continue }

                // Generate target + k * modulus for small k values
                for k in 0...10 {
                    let (value, overflow) = targetInt.addingReportingOverflow(k * modulus)
                    if !overflow {
                        mutations.append(value)
                    }

                    // Also try negative direction
                    if k > 0 {
                        let (negValue, negOverflow) = targetInt.subtractingReportingOverflow(k * modulus)
                        if !negOverflow {
                            mutations.append(negValue)
                        }
                    }
                }
            }

            return Array(Set(mutations))
        }

        /// Generate pair mutations for constraints like `a + b == target`.
        ///
        /// Given a current value for one input, generates values for the other
        /// input that would satisfy additive relationships.
        public func pairMutations(otherValue: Int) -> [Int] {
            guard let targetInt = Int(exactly: target) else { return [] }

            var mutations: [Int] = []

            // For a + b == target: b = target - a
            let (diff, overflow1) = targetInt.subtractingReportingOverflow(otherValue)
            if !overflow1 {
                mutations.append(diff)
            }

            // For modulo constraints: a + b ≡ target (mod m)
            // So b = target - a + k*m
            let commonModuli = [100, 256, 1000, 1024, 10000]
            for modulus in commonModuli {
                guard targetInt < modulus else { continue }

                for k in -5...5 {
                    let (base, o1) = targetInt.subtractingReportingOverflow(otherValue)
                    guard !o1 else { continue }
                    let (adjustment, o2) = (k * modulus).addingReportingOverflow(0) // Just to check k*modulus
                    guard !o2 else { continue }
                    let (value, o3) = base.addingReportingOverflow(k * modulus)
                    if !o3 {
                        mutations.append(value)
                    }
                }
            }

            return Array(Set(mutations))
        }
    }

    /// Extract comparison targets from the most recent test execution.
    ///
    /// Returns targets for constant comparisons that haven't been solved yet.
    /// These can be used to generate targeted mutations.
    public func extractTargets() -> [ComparisonTarget] {
        let count = vp_get_count()
        guard count > 0, let records = vp_get_records() else {
            return []
        }

        var targets: [ComparisonTarget] = []
        var seen: Set<UInt64> = []

        for i in 0..<count {
            let record = records[i]

            // Only extract from constant comparisons (magic numbers)
            guard record.is_const else { continue }

            // Skip if we've already solved this one (distance 0)
            guard record.distance > 0 else { continue }

            // Skip duplicates
            guard !seen.contains(record.arg1) else { continue }
            seen.insert(record.arg1)

            // arg1 is the constant (target), arg2 is the runtime value (current)
            targets.append(ComparisonTarget(
                target: record.arg1,
                current: record.arg2,
                isSigned: true  // Assume signed for now
            ))
        }

        return targets
    }
}
