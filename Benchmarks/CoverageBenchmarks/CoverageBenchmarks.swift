//
//  CoverageBenchmarks.swift
//  PropertyTestingKit
//
//  Performance benchmarks for coverage-related operations.
//
//  Note: This file includes minimal implementations of types from PropertyTestingKit
//  because the main library uses parameter packs which crash Swift 6.2 in release mode.
//

import Benchmark
import Foundation
import ValueProfileHooks

// MARK: - Minimal Type Implementations for Benchmarking

/// Minimal CoverageSignature implementation for benchmarking.
/// Matches the real implementation's performance characteristics.
struct BenchmarkCoverageSignature: Hashable, Sendable {
    enum Bucket: UInt8, Hashable, Sendable {
        case zero = 0
        case one = 1
        case two = 2
        case threeToFour = 3
        case fiveToEight = 4
        case nineToSixteen = 5
        case seventeenPlus = 6

        init(count: UInt64) {
            switch count {
            case 0: self = .zero
            case 1: self = .one
            case 2: self = .two
            case 3...4: self = .threeToFour
            case 5...8: self = .fiveToEight
            case 9...16: self = .nineToSixteen
            default: self = .seventeenPlus
            }
        }
    }

    let buckets: [Int: Bucket]

    /// Create from sparse coverage data (only non-zero counters).
    /// This is the OPTIMIZED path.
    init(sparseCoverage: [Int: UInt8]) {
        var buckets: [Int: Bucket] = [:]
        buckets.reserveCapacity(sparseCoverage.count)
        for (index, count) in sparseCoverage {
            let bucket = Bucket(count: UInt64(count))
            if bucket != .zero {
                buckets[index] = bucket
            }
        }
        self.buckets = buckets
    }

    /// Create from full counter array (iterates all counters).
    /// This is the SLOW path we're comparing against.
    init(fullCounters: [UInt8]) {
        var buckets: [Int: Bucket] = [:]
        for (index, count) in fullCounters.enumerated() {
            let bucket = Bucket(count: UInt64(count))
            if bucket != .zero {
                buckets[index] = bucket
            }
        }
        self.buckets = buckets
    }

    func hasUniqueCoverage(comparedTo other: BenchmarkCoverageSignature) -> Bool {
        for (index, bucket) in buckets {
            if other.buckets[index] != bucket {
                return true
            }
        }
        return false
    }

    func union(with other: BenchmarkCoverageSignature) -> BenchmarkCoverageSignature {
        var merged = buckets
        for (index, bucket) in other.buckets {
            if let existing = merged[index] {
                merged[index] = max(existing, bucket)
            } else {
                merged[index] = bucket
            }
        }
        return BenchmarkCoverageSignature(buckets: merged)
    }

    private init(buckets: [Int: Bucket]) {
        self.buckets = buckets
    }
}

extension BenchmarkCoverageSignature.Bucket: Comparable {
    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Test Data Setup

/// Generate a sparse coverage dictionary simulating typical fuzz test coverage.
func makeSparseCoverage(coveredCount: Int, totalEdges: Int) -> [Int: UInt8] {
    var coverage: [Int: UInt8] = [:]
    coverage.reserveCapacity(coveredCount)

    let step = max(1, totalEdges / coveredCount)
    for i in 0..<coveredCount {
        let index = (i * step + i * 7) % totalEdges
        coverage[index] = UInt8(1 + (i % 10))
    }
    return coverage
}

/// Generate a full counter array simulating a SanCovCounters snapshot.
func makeFullCounters(coveredCount: Int, totalEdges: Int) -> [UInt8] {
    var counters = [UInt8](repeating: 0, count: totalEdges)

    let step = max(1, totalEdges / coveredCount)
    for i in 0..<coveredCount {
        let index = (i * step + i * 7) % totalEdges
        counters[index] = UInt8(1 + (i % 10))
    }
    return counters
}

// MARK: - Benchmarks

let benchmarks: @Sendable () -> Void = {
    // Typical parameters matching real-world usage:
    // - ~26,000 total instrumented edges
    // - ~5-50 edges covered per test execution
    let totalEdges = 26_000
    let typicalCoveredEdges = 10
    let largeCoveredEdges = 100

    // Pre-generate test data to avoid measuring allocation in benchmarks
    let sparseSmall = makeSparseCoverage(coveredCount: typicalCoveredEdges, totalEdges: totalEdges)
    let sparseLarge = makeSparseCoverage(coveredCount: largeCoveredEdges, totalEdges: totalEdges)
    let fullCountersSmall = makeFullCounters(coveredCount: typicalCoveredEdges, totalEdges: totalEdges)
    let fullCountersLarge = makeFullCounters(coveredCount: largeCoveredEdges, totalEdges: totalEdges)

    // MARK: - CoverageSignature Creation - Sparse (Optimized)

    Benchmark(
        "CoverageSignature(sparse) - 10 edges",
        configuration: .init(
            metrics: [.cpuTotal, .wallClock, .mallocCountTotal],
            warmupIterations: 100,
            scalingFactor: .kilo
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(BenchmarkCoverageSignature(sparseCoverage: sparseSmall))
        }
    }

    Benchmark(
        "CoverageSignature(sparse) - 100 edges",
        configuration: .init(
            metrics: [.cpuTotal, .wallClock, .mallocCountTotal],
            warmupIterations: 100,
            scalingFactor: .kilo
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(BenchmarkCoverageSignature(sparseCoverage: sparseLarge))
        }
    }

    // MARK: - CoverageSignature Creation - Full (Slow Path)

    Benchmark(
        "CoverageSignature(full) - 10 edges in 26K",
        configuration: .init(
            metrics: [.cpuTotal, .wallClock, .mallocCountTotal],
            warmupIterations: 10,
            scalingFactor: .one
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(BenchmarkCoverageSignature(fullCounters: fullCountersSmall))
        }
    }

    Benchmark(
        "CoverageSignature(full) - 100 edges in 26K",
        configuration: .init(
            metrics: [.cpuTotal, .wallClock, .mallocCountTotal],
            warmupIterations: 10,
            scalingFactor: .one
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(BenchmarkCoverageSignature(fullCounters: fullCountersLarge))
        }
    }

    // MARK: - C-Level Snapshot Operations

    Benchmark(
        "sancov_snapshot_covered_indices (count only)",
        configuration: .init(
            metrics: [.cpuTotal, .wallClock],
            warmupIterations: 100,
            scalingFactor: .kilo
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(sancov_snapshot_covered_indices(nil, nil, 0))
        }
    }

    Benchmark(
        "sancov_get_counter_count",
        configuration: .init(
            metrics: [.cpuTotal, .wallClock],
            warmupIterations: 100,
            scalingFactor: .kilo
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(sancov_get_counter_count())
        }
    }

    Benchmark(
        "sancov_get_covered_count",
        configuration: .init(
            metrics: [.cpuTotal, .wallClock],
            warmupIterations: 100,
            scalingFactor: .kilo
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(sancov_get_covered_count())
        }
    }

    // MARK: - Signature Comparison

    Benchmark(
        "CoverageSignature.hasUniqueCoverage",
        configuration: .init(
            metrics: [.cpuTotal, .wallClock],
            warmupIterations: 100,
            scalingFactor: .kilo
        )
    ) { benchmark in
        let sig1 = BenchmarkCoverageSignature(sparseCoverage: sparseSmall)
        let sig2 = BenchmarkCoverageSignature(sparseCoverage: sparseLarge)

        for _ in benchmark.scaledIterations {
            blackHole(sig1.hasUniqueCoverage(comparedTo: sig2))
        }
    }

    Benchmark(
        "CoverageSignature.union",
        configuration: .init(
            metrics: [.cpuTotal, .wallClock, .mallocCountTotal],
            warmupIterations: 100,
            scalingFactor: .kilo
        )
    ) { benchmark in
        let sig1 = BenchmarkCoverageSignature(sparseCoverage: sparseSmall)
        let sig2 = BenchmarkCoverageSignature(sparseCoverage: sparseLarge)

        for _ in benchmark.scaledIterations {
            blackHole(sig1.union(with: sig2))
        }
    }

    // MARK: - Dictionary Operations (Core Performance)

    Benchmark(
        "Dictionary iteration - 26K elements (sparse: 10 non-zero)",
        configuration: .init(
            metrics: [.cpuTotal, .wallClock],
            warmupIterations: 10,
            scalingFactor: .one
        )
    ) { benchmark in
        var count = 0
        for _ in benchmark.scaledIterations {
            for (_, value) in fullCountersSmall.enumerated() where value > 0 {
                count += 1
            }
        }
        blackHole(count)
    }

    Benchmark(
        "Dictionary lookup - 10 keys",
        configuration: .init(
            metrics: [.cpuTotal, .wallClock],
            warmupIterations: 100,
            scalingFactor: .kilo
        )
    ) { benchmark in
        let dict = sparseSmall
        let keys = Array(dict.keys)

        for _ in benchmark.scaledIterations {
            var sum: UInt8 = 0
            for key in keys {
                sum &+= dict[key] ?? 0
            }
            blackHole(sum)
        }
    }
}
