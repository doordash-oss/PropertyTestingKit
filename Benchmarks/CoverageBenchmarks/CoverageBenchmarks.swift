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

/// Generate a SparseCoverage struct simulating typical fuzz test coverage.
func makeSparseCoverageArrays(coveredCount: Int, totalEdges: Int) -> SparseCoverage {
    var indices: [UInt32] = []
    var counts: [UInt8] = []
    indices.reserveCapacity(coveredCount)
    counts.reserveCapacity(coveredCount)

    let step = max(1, totalEdges / coveredCount)
    for i in 0..<coveredCount {
        let index = (i * step + i * 7) % totalEdges
        indices.append(UInt32(index))
        counts.append(UInt8(1 + (i % 10)))
    }
    return SparseCoverage(indices: indices, counts: counts)
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

/// A function with an unreachable branch that creates a realistic coverage gap.
/// Uses a hash-based check that value profile guidance can't easily solve.
@inline(never)
func realisticCoverageGap(_ input: Int) {
    // Simple hash to defeat value profile guidance
    let hash = (input &* 31) ^ (input >> 4)
    if hash == 0x7FFFFFFE {
        // This branch is effectively unreachable (requires specific input)
        blackHole("found magic!")
    } else if input < 0 {
        blackHole("negative")
    } else {
        blackHole("positive")
    }
}

/// An expensive validation function that simulates realistic test workloads.
/// Takes ~100μs per call with multiple code paths for coverage.
@inline(never)
func expensiveValidation(_ input: Int) throws {
    // Simulate parsing/validation work with many branches
    var accumulator: Int = 0

    // Multiple passes over the input to create measurable work
    for iteration in 0..<100 {
        let adjusted = input &+ iteration

        if adjusted < 0 {
            accumulator &+= hashValue(adjusted, seed: 1)
        } else if adjusted == 0 {
            accumulator &+= hashValue(adjusted, seed: 2)
        } else if adjusted < 100 {
            accumulator &+= hashValue(adjusted, seed: 3)
        } else if adjusted < 1000 {
            accumulator &+= hashValue(adjusted, seed: 4)
        } else if adjusted < 10000 {
            accumulator &+= hashValue(adjusted, seed: 5)
        } else {
            accumulator &+= hashValue(adjusted, seed: 6)
        }

        // Add more branching based on bits
        if adjusted & 1 != 0 {
            accumulator &+= hashValue(adjusted, seed: 7)
        }
        if adjusted & 2 != 0 {
            accumulator &+= hashValue(adjusted, seed: 8)
        }
        if adjusted & 4 != 0 {
            accumulator &+= hashValue(adjusted, seed: 9)
        }
        if adjusted & 8 != 0 {
            accumulator &+= hashValue(adjusted, seed: 10)
        }
    }

    blackHole(accumulator)
}

/// Hash function to create work and prevent optimization.
@inline(never)
func hashValue(_ value: Int, seed: Int) -> Int {
    var result = value ^ seed
    for _ in 0..<10 {
        result = result &* 31 &+ seed
        result = result ^ (result >> 7)
    }
    return result
}

/// A Fuzzable type with empty fuzz array and empty mutations.
/// Used to benchmark edge case handling in FuzzEngine.
struct EmptyFuzzable: Fuzzable, Codable, Sendable, Equatable {
    let value: Int
    static var fuzz: [EmptyFuzzable] { [] }
    func mutate() -> [EmptyFuzzable] { [] }
}

/// Nested Fuzzable types for benchmarking cartesian product generation.
@Fuzzable
struct BenchDog: Codable, Sendable, Equatable, Hashable {
    let age: Int
    let isBrown: Bool
}

@Fuzzable
struct BenchHuman: Codable, Sendable, Equatable, Hashable {
    let age: Int
    let dog: BenchDog
}

// MARK: - Benchmarks

let benchmarks: @Sendable () -> Void = {
    let totalEdges = 26_000
    let typicalCoveredEdges = 10
    let largeCoveredEdges = 100

    // Pre-generate test data (dictionary format - deprecated)
    let sparseSmall = makeSparseCoverage(coveredCount: typicalCoveredEdges, totalEdges: totalEdges)
    let sparseLarge = makeSparseCoverage(coveredCount: largeCoveredEdges, totalEdges: totalEdges)
    let fullCountersSmall = makeFullCounters(coveredCount: typicalCoveredEdges, totalEdges: totalEdges)
    let fullCountersLarge = makeFullCounters(coveredCount: largeCoveredEdges, totalEdges: totalEdges)

    // Pre-generate test data (array format - optimized)
    let sparseArraysSmall = makeSparseCoverageArrays(coveredCount: typicalCoveredEdges, totalEdges: totalEdges)
    let sparseArraysLarge = makeSparseCoverageArrays(coveredCount: largeCoveredEdges, totalEdges: totalEdges)

    // MARK: - CoverageSignature Creation

    Benchmark(
        "CoverageSignature(sparse) - 10 edges",
        configuration: .init(
            metrics: [.wallClock],
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
            metrics: [.wallClock],
            warmupIterations: 100,
            scalingFactor: .kilo
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(CoverageSignature(sparseCoverage: sparseLarge))
        }
    }

    // New optimized SparseCoverage benchmarks
    Benchmark(
        "CoverageSignature(SparseCoverage) - 10 edges",
        configuration: .init(
            metrics: [.wallClock],
            warmupIterations: 100,
            scalingFactor: .kilo
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(CoverageSignature(sparse: sparseArraysSmall))
        }
    }

    Benchmark(
        "CoverageSignature(SparseCoverage) - 100 edges",
        configuration: .init(
            metrics: [.wallClock],
            warmupIterations: 100,
            scalingFactor: .kilo
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(CoverageSignature(sparse: sparseArraysLarge))
        }
    }

    Benchmark(
        "CoverageSignature(full) - 10 edges in 26K",
        configuration: .init(
            metrics: [.wallClock],
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
            metrics: [.wallClock],
            warmupIterations: 10,
            scalingFactor: .one
        )
    ) { benchmark in
        let snapshot = SanCovCounters(counters: fullCountersLarge)
        for _ in benchmark.scaledIterations {
            blackHole(CoverageSignature(snapshot: snapshot))
        }
    }

    // MARK: - Fuzz Benchmarks

    Benchmark(
        "fuzz(Int) - 100 iterations, refuzzReplace",
        configuration: .init(
            metrics: [.wallClock],
            warmupIterations: 1,
            scalingFactor: .one,
            maxDuration: .seconds(30),
            maxIterations: 10
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            let _ = try? await fuzz(
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
        "fuzz(Int) - 100 iterations, no value profile",
        configuration: .init(
            metrics: [.wallClock],
            warmupIterations: 1,
            scalingFactor: .one,
            maxDuration: .seconds(30),
            maxIterations: 10
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            let config = FuzzEngine<Int>.Config(
                maxIterations: 100,
                maxDuration: 1,
                enableValueProfile: false,
                corpusMode: .refuzzReplace
            )
            let engine = FuzzEngine<Int>(config: config)
            let _ = await engine.run { input in
                try parseAndValidate(input)
            }
        }
    }

    Benchmark(
        "fuzz(Int) - 100 iterations, refuzzReplace, with gap detection",
        configuration: .init(
            metrics: [.wallClock],
            warmupIterations: 1,
            scalingFactor: .one,
            maxDuration: .seconds(60),
            maxIterations: 10
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            let _ = try? await fuzz(
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
            metrics: [.wallClock],
            warmupIterations: 1,
            scalingFactor: .one,
            maxDuration: .seconds(30),
            maxIterations: 10
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            let _ = try? await fuzz(
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
            metrics: [.wallClock],
            warmupIterations: 1,
            scalingFactor: .one,
            maxDuration: .seconds(60),
            maxIterations: 5
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            let _ = try? await fuzz(
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
            metrics: [.wallClock],
            warmupIterations: 1,
            scalingFactor: .one,
            maxDuration: .seconds(60),
            maxIterations: 5
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            let _ = try? await fuzz(
                iterations: 1000,
                duration: 10,
                corpusMode: .refuzzReplace,
                detectCoverageGaps: true
            ) { (input: Int) in
                try parseAndValidate(input)
            }
        }
    }

    Benchmark(
        "fuzz(Int) - realistic coverage gap, with gap detection",
        configuration: .init(
            metrics: [.wallClock],
            warmupIterations: 1,
            scalingFactor: .one,
            maxDuration: .seconds(60),
            maxIterations: 5
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            let _ = try? await fuzz(
                iterations: 100,
                duration: 5,
                corpusMode: .refuzzReplace,
                detectCoverageGaps: true
            ) { (input: Int) in
                realisticCoverageGap(input)
            }
        }
    }

    Benchmark(
        "fuzz(EmptyFuzzable) - empty fuzz array",
        configuration: .init(
            metrics: [.wallClock],
            warmupIterations: 1,
            scalingFactor: .one,
            maxDuration: .seconds(30),
            maxIterations: 5
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            let config = FuzzEngine<EmptyFuzzable>.Config(
                maxIterations: 10,
                maxDuration: 1,
                corpusMode: .refuzzReplace
            )
            let engine = FuzzEngine<EmptyFuzzable>(config: config, corpusDirectory: nil)
            let _ = await engine.run { _ in }
        }
    }

    // MARK: - Corpus Operations

    Benchmark(
        "Corpus.addIfInteresting - empty corpus",
        configuration: .init(
            metrics: [.wallClock],
            warmupIterations: 5,
            scalingFactor: .kilo
        )
    ) { benchmark async in
        for _ in benchmark.scaledIterations {
            let corpus = await Corpus<Int>(schemaVersion: "bench-v1")
            let sig = CoverageSignature(sparseCoverage: sparseSmall)
            blackHole(await corpus.addIfInteresting(input: 42, signature: sig))
        }
    }

    Benchmark(
        "Corpus.addIfInteresting - 100 entries",
        configuration: .init(
            metrics: [.wallClock],
            warmupIterations: 5,
            scalingFactor: .kilo
        )
    ) { benchmark async in
        let corpus = await Corpus<Int>(schemaVersion: "bench-v1")
        for i in 0..<100 {
            let sig = CoverageSignature(sparseCoverage: makeSparseCoverage(
                coveredCount: typicalCoveredEdges,
                totalEdges: totalEdges
            ))
            await corpus.add(input: i, signature: sig)
        }

        for _ in benchmark.scaledIterations {
            let sig = CoverageSignature(sparseCoverage: sparseSmall)
            blackHole(await corpus.addIfInteresting(input: 999, signature: sig))
        }
    }

    // MARK: - Signature Operations

    Benchmark(
        "CoverageSignature.hasUniqueCoverage",
        configuration: .init(
            metrics: [.wallClock],
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
            metrics: [.wallClock],
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
            metrics: [.wallClock],
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
            metrics: [.wallClock],
            warmupIterations: 100,
            scalingFactor: .kilo
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(SanCovCounters.currentCoveredCount)
        }
    }

    // MARK: - Coverage Snapshot Benchmarks
    // Note: SanCovCounters.snapshot() is not benchmarked directly because
    // the benchmark binary itself is instrumented, creating millions of edges.
    // Instead we benchmark operations with pre-created data.

    Benchmark(
        "SanCovCounters.reset()",
        configuration: .init(
            metrics: [.wallClock],
            warmupIterations: 100,
            scalingFactor: .kilo
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            SanCovCounters.reset()
        }
    }

    // MARK: - Mutation Strategy Benchmarks

    Benchmark(
        "Int.mutate() - single value",
        configuration: .init(
            metrics: [.wallClock],
            warmupIterations: 100,
            scalingFactor: .kilo
        )
    ) { benchmark in
        let value = 42
        for _ in benchmark.scaledIterations {
            blackHole(value.mutate())
        }
    }

    Benchmark(
        "String.mutate() - short string",
        configuration: .init(
            metrics: [.wallClock],
            warmupIterations: 100,
            scalingFactor: .kilo
        )
    ) { benchmark in
        let value = "hello"
        for _ in benchmark.scaledIterations {
            blackHole(value.mutate())
        }
    }

    Benchmark(
        "String.mutate() - medium string",
        configuration: .init(
            metrics: [.wallClock],
            warmupIterations: 100,
            scalingFactor: .kilo
        )
    ) { benchmark in
        let value = String(repeating: "a", count: 100)
        for _ in benchmark.scaledIterations {
            blackHole(value.mutate())
        }
    }

    Benchmark(
        "[Int].mutate() - small array",
        configuration: .init(
            metrics: [.wallClock],
            warmupIterations: 100,
            scalingFactor: .kilo
        )
    ) { benchmark in
        let value = [1, 2, 3, 4, 5]
        for _ in benchmark.scaledIterations {
            blackHole(value.mutate())
        }
    }

    Benchmark(
        "[Int].mutate() - medium array",
        configuration: .init(
            metrics: [.wallClock],
            warmupIterations: 100,
            scalingFactor: .kilo
        )
    ) { benchmark in
        let value = Array(1...50)
        for _ in benchmark.scaledIterations {
            blackHole(value.mutate())
        }
    }

    // MARK: - Plateau Detection Benchmarks

    Benchmark(
        "CoveragePlateauDetector.record - no discovery",
        configuration: .init(
            metrics: [.wallClock],
            warmupIterations: 100,
            scalingFactor: .kilo
        )
    ) { benchmark async in
        for _ in benchmark.scaledIterations {
            var detector = CoveragePlateauDetector()
            for _ in 0..<100 {
                await detector.record(discoveredNewCoverage: false)
            }
            blackHole(detector.hasPlateaued)
        }
    }

    Benchmark(
        "CoveragePlateauDetector.record - mixed discovery",
        configuration: .init(
            metrics: [.wallClock],
            warmupIterations: 100,
            scalingFactor: .kilo
        )
    ) { benchmark async in
        for _ in benchmark.scaledIterations {
            var detector = CoveragePlateauDetector()
            for i in 0..<100 {
                await detector.record(discoveredNewCoverage: i % 10 == 0)
            }
            blackHole(detector.hasPlateaued)
        }
    }

    // MARK: - Corpus Growth Benchmarks

    Benchmark(
        "Corpus growth - 100 entries",
        configuration: .init(
            metrics: [.wallClock],
            warmupIterations: 5,
            scalingFactor: .one
        )
    ) { benchmark async in
        for _ in benchmark.scaledIterations {
            let corpus = await Corpus<Int>(schemaVersion: "bench-v1")
            for i in 0..<100 {
                let sig = CoverageSignature(sparseCoverage: makeSparseCoverage(
                    coveredCount: typicalCoveredEdges + i,
                    totalEdges: totalEdges
                ))
                await corpus.add(input: i, signature: sig)
            }
            blackHole(await corpus.count)
        }
    }

    Benchmark(
        "Corpus.selectForMutation - 100 entries",
        configuration: .init(
            metrics: [.wallClock],
            warmupIterations: 100,
            scalingFactor: .kilo
        )
    ) { benchmark async in
        let corpus = await Corpus<Int>(schemaVersion: "bench-v1")
        for i in 0..<100 {
            let sig = CoverageSignature(sparseCoverage: makeSparseCoverage(
                coveredCount: typicalCoveredEdges,
                totalEdges: totalEdges
            ))
            await corpus.add(input: i, signature: sig)
        }

        for _ in benchmark.scaledIterations {
            blackHole(await corpus.selectForMutation())
        }
    }

    Benchmark(
        "Corpus.minimized - 100 entries",
        configuration: .init(
            metrics: [.wallClock],
            warmupIterations: 1,
            scalingFactor: .one
        )
    ) { benchmark async in
        let corpus = await Corpus<Int>(schemaVersion: "bench-v1")
        for i in 0..<100 {
            // Create overlapping signatures to test minimization
            let sig = CoverageSignature(sparseCoverage: makeSparseCoverage(
                coveredCount: typicalCoveredEdges,
                totalEdges: totalEdges
            ))
            await corpus.add(input: i, signature: sig)
        }

        for _ in benchmark.scaledIterations {
            blackHole(await corpus.minimized())
        }
    }

    Benchmark(
        "Int.fuzz generation",
        configuration: .init(
            metrics: [.wallClock],
            warmupIterations: 100,
            scalingFactor: .kilo
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(Int.fuzz)
        }
    }

    Benchmark(
        "String.fuzz generation",
        configuration: .init(
            metrics: [.wallClock],
            warmupIterations: 100,
            scalingFactor: .kilo
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(String.fuzz)
        }
    }

    Benchmark(
        "[Int].fuzz generation",
        configuration: .init(
            metrics: [.wallClock],
            warmupIterations: 100,
            scalingFactor: .kilo
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole([Int].fuzz)
        }
    }
    // MARK: - Fuzz Overhead Deep Dive Benchmarks

    Benchmark(
        "fuzz(Int) - 10 iterations only (minimal)",
        configuration: .init(
            metrics: [.wallClock],
            warmupIterations: 5,
            scalingFactor: .one,
            maxDuration: .seconds(30),
            maxIterations: 20
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            let _ = try? await fuzz(
                iterations: 10,
                duration: 1,
                corpusMode: .refuzzReplace,
                detectCoverageGaps: false
            ) { (input: Int) in
                // Minimal test - just touch the input
                blackHole(input)
            }
        }
    }

    Benchmark(
        "fuzz(Int) - 50 iterations only",
        configuration: .init(
            metrics: [.wallClock],
            warmupIterations: 3,
            scalingFactor: .one,
            maxDuration: .seconds(30),
            maxIterations: 15
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            let _ = try? await fuzz(
                iterations: 50,
                duration: 1,
                corpusMode: .refuzzReplace,
                detectCoverageGaps: false
            ) { (input: Int) in
                blackHole(input)
            }
        }
    }

    // MARK: - Seed Phase Simulation Benchmarks
    // These simulate what happens during the seed phase of fuzz()

    Benchmark(
        "Seed iteration: reset + test + snapshot + signature + corpus",
        configuration: .init(
            metrics: [.wallClock],
            warmupIterations: 10,
            scalingFactor: .one,
            maxDuration: .seconds(10),
            maxIterations: 100
        )
    ) { benchmark async in
        for _ in benchmark.scaledIterations {
            // This simulates one seed iteration in the fuzz loop
            let corpus = await Corpus<Int>(schemaVersion: "bench-v1")

            // Process all Int.fuzz seeds (21 values)
            for input in Int.fuzz {
                // 1. Reset coverage
                SanCovCounters.reset()

                // 2. Run test
                blackHole(try? parseAndValidate(input))

                // 3. Snapshot coverage
                if let sparse = SanCovCounters.snapshotCoveredArrays() {
                    // 4. Create signature
                    let sig = CoverageSignature(sparse: sparse)

                    // 5. Add to corpus if interesting
                    blackHole(await corpus.addIfInteresting(input: input, signature: sig))
                }
            }
        }
    }

    Benchmark(
        "Single seed iteration: reset + test + snapshot + signature + corpus",
        configuration: .init(
            metrics: [.wallClock],
            warmupIterations: 100,
            scalingFactor: .kilo
        )
    ) { benchmark async in
        let corpus = await Corpus<Int>(schemaVersion: "bench-v1")

        for _ in benchmark.scaledIterations {
            // 1. Reset coverage
            SanCovCounters.reset()

            // 2. Run test
            blackHole(try? parseAndValidate(42))

            // 3. Snapshot coverage
            if let sparse = SanCovCounters.snapshotCoveredArrays() {
                // 4. Create signature
                let sig = CoverageSignature(sparse: sparse)

                // 5. Add to corpus if interesting
                blackHole(await corpus.addIfInteresting(input: 42, signature: sig))
            }
        }
    }

    // MARK: - Overhead Source Benchmarks

    Benchmark(
        "SanCovCounters.snapshotCoveredOnly()",
        configuration: .init(
            metrics: [.wallClock],
            warmupIterations: 10,
            scalingFactor: .kilo
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(SanCovCounters.snapshotCoveredOnly())
        }
    }

    Benchmark(
        "SanCovCounters.snapshotCoveredArrays()",
        configuration: .init(
            metrics: [.wallClock],
            warmupIterations: 10,
            scalingFactor: .kilo
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(SanCovCounters.snapshotCoveredArrays())
        }
    }

    Benchmark(
        "SanCovCounters.snapshot() - full",
        configuration: .init(
            metrics: [.wallClock],
            warmupIterations: 10,
            scalingFactor: .one
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(SanCovCounters.snapshot())
        }
    }

    // MARK: - Nested Fuzzable Benchmarks

    Benchmark(
        "BenchHuman.fuzz generation",
        configuration: .init(
            metrics: [.wallClock],
            warmupIterations: 10,
            scalingFactor: .one
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(BenchHuman.fuzz)
        }
    }

    Benchmark(
        "BenchDog.fuzz generation",
        configuration: .init(
            metrics: [.wallClock],
            warmupIterations: 10,
            scalingFactor: .kilo
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(BenchDog.fuzz)
        }
    }

    Benchmark(
        "Nested fuzzable contains all combinations (O(n²) check)",
        configuration: .init(
            metrics: [.wallClock],
            warmupIterations: 1,
            scalingFactor: .one,
            maxDuration: .seconds(30),
            maxIterations: 5
        )
    ) { benchmark in
        // This mirrors the nestedFuzzableContainsAllCombinations test
        for _ in benchmark.scaledIterations {
            let humans = BenchHuman.fuzz

            // O(n²) verification - same as the test
            for humanAge in Int.fuzz {
                for dog in BenchDog.fuzz {
                    let matchingHuman = humans.contains {
                        $0.age == humanAge && $0.dog.age == dog.age && $0.dog.isBrown == dog.isBrown
                    }
                    blackHole(matchingHuman)
                }
            }
        }
    }

    Benchmark(
        "Nested fuzzable O(n) check using Set",
        configuration: .init(
            metrics: [.wallClock],
            warmupIterations: 10,
            scalingFactor: .one,
            maxDuration: .seconds(30),
            maxIterations: 100
        )
    ) { benchmark in
        // This shows the improvement possible with a Set-based approach
        for _ in benchmark.scaledIterations {
            let humans = BenchHuman.fuzz
            let humanSet = Set(humans)

            // O(n) verification using Set
            for humanAge in Int.fuzz {
                for dog in BenchDog.fuzz {
                    let candidate = BenchHuman(age: humanAge, dog: dog)
                    let matchingHuman = humanSet.contains(candidate)
                    blackHole(matchingHuman)
                }
            }
        }
    }

    // MARK: - Expensive Test Function Benchmarks (Real Coverage)
    // These benchmarks use computationally expensive test functions to simulate
    // realistic fuzzing scenarios where parallelization benefits outweigh overhead.

    Benchmark(
        "fuzz(Int) - 100 iterations, expensive test (real coverage)",
        configuration: .init(
            metrics: [.wallClock],
            warmupIterations: 1,
            scalingFactor: .one,
            maxDuration: .seconds(60),
            maxIterations: 5
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            let _ = try? await fuzz(
                iterations: 100,
                duration: 30,
                corpusMode: .refuzzReplace,
                detectCoverageGaps: false
            ) { (input: Int) in
                try expensiveValidation(input)
            }
        }
    }

    Benchmark(
        "fuzz(Int) - 100 iterations, expensive test, batchSize=1 (sequential)",
        configuration: .init(
            metrics: [.wallClock],
            warmupIterations: 1,
            scalingFactor: .one,
            maxDuration: .seconds(60),
            maxIterations: 5
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            let config = FuzzEngine<Int>.Config(
                maxIterations: 100,
                maxDuration: 30,
                corpusMode: .refuzzReplace,
                mutationBatchSize: 1  // Force sequential execution
            )
            let engine = FuzzEngine<Int>(config: config)
            let _ = await engine.run { input in
                try expensiveValidation(input)
            }
        }
    }

    Benchmark(
        "fuzz(Int) - 100 iterations, expensive test, batchSize=16",
        configuration: .init(
            metrics: [.wallClock],
            warmupIterations: 1,
            scalingFactor: .one,
            maxDuration: .seconds(60),
            maxIterations: 5
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            let config = FuzzEngine<Int>.Config(
                maxIterations: 100,
                maxDuration: 30,
                corpusMode: .refuzzReplace,
                mutationBatchSize: 16
            )
            let engine = FuzzEngine<Int>(config: config)
            let _ = await engine.run { input in
                try expensiveValidation(input)
            }
        }
    }

}
