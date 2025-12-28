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

/// Generate a SparseCoverage struct simulating typical fuzz test coverage.
func makeSparseCoverageArrays(coveredCount: Int, totalEdges: Int) -> SparseCoverage {
    // Clamp to avoid duplicates
    let actualCount = min(coveredCount, totalEdges)

    var indices: [UInt32] = []
    var counts: [UInt8] = []
    indices.reserveCapacity(actualCount)
    counts.reserveCapacity(actualCount)

    // Use sequential indices for simplicity and guaranteed uniqueness
    for i in 0..<actualCount {
        indices.append(UInt32(i))
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

// MARK: - Benchmarks

let benchmarks: @Sendable () -> Void = {
    let totalEdges = 26_000
    let typicalCoveredEdges = 10
    let largeCoveredEdges = 100

    // Pre-generate test data (dictionary format - deprecated)
    let fullCountersSmall = makeFullCounters(coveredCount: typicalCoveredEdges, totalEdges: totalEdges)
    let fullCountersLarge = makeFullCounters(coveredCount: largeCoveredEdges, totalEdges: totalEdges)

    // Pre-generate test data (array format - optimized)
    let sparseArraysSmall = makeSparseCoverageArrays(coveredCount: typicalCoveredEdges, totalEdges: totalEdges)
    let sparseArraysLarge = makeSparseCoverageArrays(coveredCount: largeCoveredEdges, totalEdges: totalEdges)

    // MARK: - CoverageSignature Creation

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
            warmupIterations: 5,
            scalingFactor: .one,
            maxDuration: .seconds(120),
            maxIterations: 100
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            let config = FuzzEngine<Int>.Config(
                maxIterations: 100,
                maxDuration: 1,
                corpusMode: .refuzzReplace,
                stoppingPlugins: []
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
            maxDuration: .seconds(120),
            maxIterations: 100
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            let config = FuzzEngine<Int>.Config(
                maxIterations: 100,
                maxDuration: 1,
                corpusMode: .refuzzReplace,
                stoppingPlugins: [],
                analysisPlugins: [.coverageGaps()]
            )
            let engine = FuzzEngine<Int>(config: config)
            let _ = await engine.run { input in
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
            maxDuration: .seconds(120),
            maxIterations: 100
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            let config = FuzzEngine<String>.Config(
                maxIterations: 100,
                maxDuration: 1,
                corpusMode: .refuzzReplace,
                stoppingPlugins: []
            )
            let engine = FuzzEngine<String>(config: config)
            let _ = await engine.run { input in
                try validateString(input)
            }
        }
    }

    Benchmark(
        "fuzz(Int) - 1000 iterations, refuzzReplace",
        configuration: .init(
            metrics: [.wallClock],
            warmupIterations: 0,
            scalingFactor: .one,
            maxDuration: .seconds(60),
            maxIterations: 1000
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            let config = FuzzEngine<Int>.Config(
                maxIterations: 1000,
                corpusMode: .refuzzReplace,
                stoppingPlugins: []
            )
            let engine = FuzzEngine<Int>(config: config)
            let _ = await engine.run { input in
                try parseAndValidate(input)
            }
        }
    }

    Benchmark(
        "fuzz(Int) - 1000 iterations, with gap detection",
        configuration: .init(
            metrics: [.wallClock],
            warmupIterations: 0,
            scalingFactor: .one,
            maxDuration: .seconds(60),
            maxIterations: 1000
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            let config = FuzzEngine<Int>.Config(
                maxIterations: 1000,
                corpusMode: .refuzzReplace,
                stoppingPlugins: [],
                analysisPlugins: [.coverageGaps()]
            )
            let engine = FuzzEngine<Int>(config: config)
            let _ = await engine.run { input in
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
            maxDuration: .seconds(120),
            maxIterations: 100
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            let config = FuzzEngine<Int>.Config(
                maxIterations: 100,
                maxDuration: 5,
                corpusMode: .refuzzReplace,
                stoppingPlugins: [],
                analysisPlugins: [.coverageGaps()]
            )
            let engine = FuzzEngine<Int>(config: config)
            let _ = await engine.run { input in
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
            maxDuration: .seconds(120),
            maxIterations: 100
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            let config = FuzzEngine<EmptyFuzzable>.Config(
                maxIterations: 10,
                maxDuration: 1,
                corpusMode: .refuzzReplace,
                stoppingPlugins: []
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
            let corpus = Corpus<Int>(schemaVersion: "bench-v1")
            let sig = CoverageSignature(sparse: sparseArraysSmall)
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
        let corpus = Corpus<Int>(schemaVersion: "bench-v1")
        for i in 0..<100 {
            let sig = CoverageSignature(sparse: makeSparseCoverageArrays(
                coveredCount: typicalCoveredEdges,
                totalEdges: totalEdges
            ))
            await corpus.add(input: i, signature: sig)
        }

        for _ in benchmark.scaledIterations {
            let sig = CoverageSignature(sparse: sparseArraysSmall)
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
        let sig1 = CoverageSignature(sparse: sparseArraysSmall)
        let sig2 = CoverageSignature(sparse: sparseArraysLarge)

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
        let sig1 = CoverageSignature(sparse: sparseArraysSmall)
        let sig2 = CoverageSignature(sparse: sparseArraysLarge)

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
        "SimpleCoveragePlateauDetector.record - no discovery",
        configuration: .init(
            metrics: [.wallClock],
            warmupIterations: 100,
            scalingFactor: .kilo
        )
    ) { benchmark async in
        for _ in benchmark.scaledIterations {
            var detector = SimpleCoveragePlateauDetector()
            for _ in 0..<100 {
                detector.record(discoveredNewCoverage: false)
            }
            blackHole(detector.hasPlateaued)
        }
    }

    Benchmark(
        "SimpleCoveragePlateauDetector.record - mixed discovery",
        configuration: .init(
            metrics: [.wallClock],
            warmupIterations: 100,
            scalingFactor: .kilo
        )
    ) { benchmark async in
        for _ in benchmark.scaledIterations {
            var detector = SimpleCoveragePlateauDetector()
            for i in 0..<100 {
                detector.record(discoveredNewCoverage: i % 10 == 0)
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
            let corpus = Corpus<Int>(schemaVersion: "bench-v1")
            for i in 0..<100 {
                let sig = CoverageSignature(sparse: makeSparseCoverageArrays(
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
        let corpus = Corpus<Int>(schemaVersion: "bench-v1")
        for i in 0..<100 {
            let sig = CoverageSignature(sparse: makeSparseCoverageArrays(
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
        let corpus = Corpus<Int>(schemaVersion: "bench-v1")
        for i in 0..<100 {
            // Create overlapping signatures to test minimization
            let sig = CoverageSignature(sparse: makeSparseCoverageArrays(
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
            maxDuration: .seconds(120),
            maxIterations: 100
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            let config = FuzzEngine<Int>.Config(
                maxIterations: 10,
                maxDuration: 1,
                corpusMode: .refuzzReplace,
                stoppingPlugins: []
            )
            let engine = FuzzEngine<Int>(config: config)
            let _ = await engine.run { input in
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
            maxDuration: .seconds(120),
            maxIterations: 100
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            let config = FuzzEngine<Int>.Config(
                maxIterations: 50,
                maxDuration: 1,
                corpusMode: .refuzzReplace,
                stoppingPlugins: []
            )
            let engine = FuzzEngine<Int>(config: config)
            let _ = await engine.run { input in
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
            let corpus = Corpus<Int>(schemaVersion: "bench-v1")

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
        let corpus = Corpus<Int>(schemaVersion: "bench-v1")

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
            blackHole(SanCovCounters.snapshotCoveredArrays())
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

    // MARK: - Expensive Test Function Benchmarks (Real Coverage)
    // These benchmarks use computationally expensive test functions to simulate
    // realistic fuzzing scenarios where parallelization benefits outweigh overhead.

    Benchmark(
        "fuzz(Int) - 100 iterations, expensive test (real coverage)",
        configuration: .init(
            metrics: [.wallClock],
            warmupIterations: 1,
            scalingFactor: .one,
            maxDuration: .seconds(120),
            maxIterations: 100
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            let config = FuzzEngine<Int>.Config(
                maxIterations: 100,
                maxDuration: 30,
                corpusMode: .refuzzReplace,
                stoppingPlugins: []
            )
            let engine = FuzzEngine<Int>(config: config)
            let _ = await engine.run { input in
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
            maxDuration: .seconds(120),
            maxIterations: 100
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            let config = FuzzEngine<Int>.Config(
                maxIterations: 100,
                maxDuration: 30,
                corpusMode: .refuzzReplace,
                mutationBatchSize: 1,  // Force sequential execution
                stoppingPlugins: []
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
            maxDuration: .seconds(120),
            maxIterations: 100
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            let config = FuzzEngine<Int>.Config(
                maxIterations: 100,
                maxDuration: 30,
                corpusMode: .refuzzReplace,
                mutationBatchSize: 16,
                stoppingPlugins: []
            )
            let engine = FuzzEngine<Int>(config: config)
            let _ = await engine.run { input in
                try expensiveValidation(input)
            }
        }
    }

    // Benchmark to test mutex contention with parallel fuzz engines
    Benchmark(
        "fuzz(Int) - 8 parallel engines, 100 iterations each",
        configuration: .init(
            metrics: [.wallClock],
            warmupIterations: 0,
            scalingFactor: .one,
            maxDuration: .seconds(120),
            maxIterations: 100
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<8 {
                    group.addTask {
                        let config = FuzzEngine<Int>.Config(
                            maxIterations: 100,
                            corpusMode: .refuzzReplace,
                            mutationBatchSize: 1,  // Sequential to maximize edge hits per engine
                            stoppingPlugins: []
                        )
                        let engine = FuzzEngine<Int>(config: config)
                        let _ = await engine.run { input in
                            try parseAndValidate(input)
                        }
                    }
                }
            }
        }
    }

    // Even more parallel engines to stress test
    Benchmark(
        "fuzz(Int) - 16 parallel engines, 100 iterations each",
        configuration: .init(
            metrics: [.wallClock],
            warmupIterations: 0,
            scalingFactor: .one,
            maxDuration: .seconds(120),
            maxIterations: 100
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<16 {
                    group.addTask {
                        let config = FuzzEngine<Int>.Config(
                            maxIterations: 100,
                            corpusMode: .refuzzReplace,
                            mutationBatchSize: 1,  // Sequential to maximize edge hits per engine
                            stoppingPlugins: []
                        )
                        let engine = FuzzEngine<Int>(config: config)
                        let _ = await engine.run { input in
                            try parseAndValidate(input)
                        }
                    }
                }
            }
        }
    }

}
