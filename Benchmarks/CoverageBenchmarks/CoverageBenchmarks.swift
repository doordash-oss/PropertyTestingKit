//
//  CoverageBenchmarks.swift
//  PropertyTestingKit
//
//  Performance benchmarks for coverage-related operations and fuzz API.
//
//  Build with local toolchain: TOOLCHAINS=org.swift.local swift build -c release --product CoverageBenchmarks
//  Run: swift package benchmark
//

import Benchmark
import Foundation
import PropertyTestingKit

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

// MARK: - Simple test function for fuzz benchmarks

/// A simple function to fuzz - parses an integer and checks bounds.
func parseAndValidate(_ input: Int) throws {
    if input == Int.min {
        // Edge case handling
    } else if input < 0 {
        let _ = abs(input)
    } else if input > 1000 {
        let _ = input / 2
    } else {
        let _ = input * 2
    }
}

/// String validation function for fuzzing.
func validateString(_ input: String) throws {
    if input.isEmpty {
        return
    }
    if input.count > 100 {
        let _ = input.prefix(100)
    }
    if input.contains("error") {
        // Simulate error path
    }
}

// MARK: - Benchmarks

let benchmarks: @Sendable () -> Void = {
    let totalEdges = 26_000
    let typicalCoveredEdges = 10
    let largeCoveredEdges = 100

    // Pre-generate test data
    let sparseSmall = makeSparseCoverage(coveredCount: typicalCoveredEdges, totalEdges: totalEdges)
    let sparseLarge = makeSparseCoverage(coveredCount: largeCoveredEdges, totalEdges: totalEdges)
    let fullCountersSmall = makeFullCounters(coveredCount: typicalCoveredEdges, totalEdges: totalEdges)
    let fullCountersLarge = makeFullCounters(coveredCount: largeCoveredEdges, totalEdges: totalEdges)

    // MARK: - CoverageSignature Creation

    Benchmark(
        "CoverageSignature(sparse) - 10 edges",
        configuration: .init(
            metrics: [.cpuTotal, .wallClock, .mallocCountTotal],
            warmupIterations: 100,
            scalingFactor: .kilo
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(CoverageSignature(sparseCoverage: sparseSmall))
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
            blackHole(CoverageSignature(sparseCoverage: sparseLarge))
        }
    }

    Benchmark(
        "CoverageSignature(full) - 10 edges in 26K",
        configuration: .init(
            metrics: [.cpuTotal, .wallClock, .mallocCountTotal],
            warmupIterations: 10,
            scalingFactor: .one
        )
    ) { benchmark in
        let snapshot = SanCovCounters(counters: fullCountersSmall)
        for _ in benchmark.scaledIterations {
            blackHole(CoverageSignature(snapshot: snapshot))
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
        let snapshot = SanCovCounters(counters: fullCountersLarge)
        for _ in benchmark.scaledIterations {
            blackHole(CoverageSignature(snapshot: snapshot))
        }
    }

    // MARK: - Fuzz API Benchmarks

    // Note: These benchmarks use small iteration counts to measure per-iteration overhead.
    // The fuzz function is called once per benchmark iteration.

    Benchmark(
        "fuzz(Int) - 100 iterations, refuzzReplace",
        configuration: .init(
            metrics: [.cpuTotal, .wallClock, .mallocCountTotal],
            warmupIterations: 1,
            scalingFactor: .one,
            maxDuration: .seconds(30),
            maxIterations: 10
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            let _ = try? fuzz(
                iterations: 100,
                duration: 1,
                corpusMode: .refuzzReplace,
                detectCoverageGaps: false
            ) { (input: Int) in
                try parseAndValidate(input)
            }
        }
    }

    Benchmark(
        "fuzz(Int) - 100 iterations, refuzzReplace, with gap detection",
        configuration: .init(
            metrics: [.cpuTotal, .wallClock, .mallocCountTotal],
            warmupIterations: 1,
            scalingFactor: .one,
            maxDuration: .seconds(60),
            maxIterations: 10
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            let _ = try? fuzz(
                iterations: 100,
                duration: 1,
                corpusMode: .refuzzReplace,
                detectCoverageGaps: true
            ) { (input: Int) in
                try parseAndValidate(input)
            }
        }
    }

    Benchmark(
        "fuzz(String) - 100 iterations, refuzzReplace",
        configuration: .init(
            metrics: [.cpuTotal, .wallClock, .mallocCountTotal],
            warmupIterations: 1,
            scalingFactor: .one,
            maxDuration: .seconds(30),
            maxIterations: 10
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            let _ = try? fuzz(
                iterations: 100,
                duration: 1,
                corpusMode: .refuzzReplace,
                detectCoverageGaps: false
            ) { (input: String) in
                try validateString(input)
            }
        }
    }

    Benchmark(
        "fuzz(Int) - 1000 iterations, refuzzReplace",
        configuration: .init(
            metrics: [.cpuTotal, .wallClock, .mallocCountTotal],
            warmupIterations: 1,
            scalingFactor: .one,
            maxDuration: .seconds(60),
            maxIterations: 5
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            let _ = try? fuzz(
                iterations: 1000,
                duration: 10,
                corpusMode: .refuzzReplace,
                detectCoverageGaps: false
            ) { (input: Int) in
                try parseAndValidate(input)
            }
        }
    }

    Benchmark(
        "fuzz(Int) - 1000 iterations, with gap detection",
        configuration: .init(
            metrics: [.cpuTotal, .wallClock, .mallocCountTotal],
            warmupIterations: 1,
            scalingFactor: .one,
            maxDuration: .seconds(60),
            maxIterations: 5
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            let _ = try? fuzz(
                iterations: 1000,
                duration: 10,
                corpusMode: .refuzzReplace,
                detectCoverageGaps: true
            ) { (input: Int) in
                try parseAndValidate(input)
            }
        }
    }

    // MARK: - Corpus Operations

    Benchmark(
        "Corpus.addIfInteresting - empty corpus",
        configuration: .init(
            metrics: [.cpuTotal, .wallClock, .mallocCountTotal],
            warmupIterations: 5,
            scalingFactor: .kilo
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            var corpus = Corpus<Int>(schemaVersion: "bench-v1")
            let sig = CoverageSignature(sparseCoverage: sparseSmall)
            blackHole(corpus.addIfInteresting(input: 42, signature: sig))
        }
    }

    Benchmark(
        "Corpus.addIfInteresting - 100 entries",
        configuration: .init(
            metrics: [.cpuTotal, .wallClock, .mallocCountTotal],
            warmupIterations: 5,
            scalingFactor: .kilo
        )
    ) { benchmark in
        var corpus = Corpus<Int>(schemaVersion: "bench-v1")
        for i in 0..<100 {
            let sig = CoverageSignature(sparseCoverage: makeSparseCoverage(
                coveredCount: typicalCoveredEdges,
                totalEdges: totalEdges
            ))
            corpus.add(input: i, signature: sig)
        }

        for _ in benchmark.scaledIterations {
            let sig = CoverageSignature(sparseCoverage: sparseSmall)
            blackHole(corpus.addIfInteresting(input: 999, signature: sig))
        }
    }

    // MARK: - Signature Operations

    Benchmark(
        "CoverageSignature.hasUniqueCoverage",
        configuration: .init(
            metrics: [.cpuTotal, .wallClock],
            warmupIterations: 100,
            scalingFactor: .kilo
        )
    ) { benchmark in
        let sig1 = CoverageSignature(sparseCoverage: sparseSmall)
        let sig2 = CoverageSignature(sparseCoverage: sparseLarge)

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
        let sig1 = CoverageSignature(sparseCoverage: sparseSmall)
        let sig2 = CoverageSignature(sparseCoverage: sparseLarge)

        for _ in benchmark.scaledIterations {
            blackHole(sig1.union(with: sig2))
        }
    }

    // MARK: - C-Level Operations

    Benchmark(
        "SanCovCounters.totalEdgeCount",
        configuration: .init(
            metrics: [.cpuTotal, .wallClock],
            warmupIterations: 100,
            scalingFactor: .kilo
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(SanCovCounters.totalEdgeCount)
        }
    }

    Benchmark(
        "SanCovCounters.currentCoveredCount",
        configuration: .init(
            metrics: [.cpuTotal, .wallClock],
            warmupIterations: 100,
            scalingFactor: .kilo
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(SanCovCounters.currentCoveredCount)
        }
    }
}
