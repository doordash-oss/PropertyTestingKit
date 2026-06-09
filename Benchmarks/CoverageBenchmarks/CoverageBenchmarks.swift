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
import Darwin
import Foundation
import PropertyTestingKit

// MARK: - CPU Time Measurement

/// Returns total CPU time (user + system) in nanoseconds using getrusage
func getCPUTimeNanos() -> UInt64 {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let userNanos = UInt64(usage.ru_utime.tv_sec) * 1_000_000_000 + UInt64(usage.ru_utime.tv_usec) * 1000
    let systemNanos = UInt64(usage.ru_stime.tv_sec) * 1_000_000_000 + UInt64(usage.ru_stime.tv_usec) * 1000
    return userNanos + systemNanos
}

// MARK: - Benchmarks

let benchmarks: @Sendable () -> Void = {
    Benchmark(
        "fuzz(Int) - iterations/sec",
        configuration: .init(
            metrics: [
                .custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false),
                .custom("Effective Parallelism (x100)", polarity: .prefersLarger, useScalingFactor: false),
                .custom("Elapsed (ms)", polarity: .prefersSmaller, useScalingFactor: false),
            ],
            warmupIterations: 0,
            scalingFactor: .one,
            maxDuration: .seconds(120),
            maxIterations: 25
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            let startCPU = getCPUTimeNanos()
            let startWall = DispatchTime.now().uptimeNanoseconds

            let result = try await fuzz(
                duration: .seconds(0.1),
                persistence: .replace,
                parallelism: 16
            ) { (input: Int) in
                blackHole(input)
            }

            let endCPU = getCPUTimeNanos()
            let endWall = DispatchTime.now().uptimeNanoseconds

            let cpuDelta = endCPU - startCPU
            let wallDelta = endWall - startWall

            // Effective parallelism = CPU time / wall time, multiplied by 100 for display precision
            let effectiveParallelism = wallDelta > 0 ? Int((Double(cpuDelta) / Double(wallDelta)) * 100) : 100

            // Calculate iterations/sec based on actual wallclock time, divide by 1000 for (K) display
            let wallSeconds = Double(wallDelta) / 1_000_000_000.0
            let iterationsPerSec = wallSeconds > 0 ? Int(Double(result.stats.totalInputs) / wallSeconds / 1000.0) : 0
            let elapsedMs = Int(wallDelta / 1_000_000)

            benchmark.measurement(.custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false), iterationsPerSec)
            benchmark.measurement(.custom("Effective Parallelism (x100)", polarity: .prefersLarger, useScalingFactor: false), effectiveParallelism)
            benchmark.measurement(.custom("Elapsed (ms)", polarity: .prefersSmaller, useScalingFactor: false), elapsedMs)
        }
    }

    Benchmark(
        "fuzz(Int) newEdge strategy - iterations/sec",
        configuration: .init(
            metrics: [
                .custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false),
                .custom("Effective Parallelism (x100)", polarity: .prefersLarger, useScalingFactor: false),
                .custom("Elapsed (ms)", polarity: .prefersSmaller, useScalingFactor: false),
            ],
            warmupIterations: 0,
            scalingFactor: .one,
            maxDuration: .seconds(120),
            maxIterations: 25
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            let startCPU = getCPUTimeNanos()
            let startWall = DispatchTime.now().uptimeNanoseconds

            let result = try await fuzz(
                duration: .seconds(0.1),
                persistence: .replace,
                coverageStrategy: .newEdge,
                parallelism: 16
            ) { (input: Int) in
                blackHole(input)
            }

            let endCPU = getCPUTimeNanos()
            let endWall = DispatchTime.now().uptimeNanoseconds

            let cpuDelta = endCPU - startCPU
            let wallDelta = endWall - startWall
            let effectiveParallelism = wallDelta > 0 ? Int((Double(cpuDelta) / Double(wallDelta)) * 100) : 100
            let wallSeconds = Double(wallDelta) / 1_000_000_000.0
            let iterationsPerSec = wallSeconds > 0 ? Int(Double(result.stats.totalInputs) / wallSeconds / 1000.0) : 0
            let elapsedMs = Int(wallDelta / 1_000_000)

            benchmark.measurement(.custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false), iterationsPerSec)
            benchmark.measurement(.custom("Effective Parallelism (x100)", polarity: .prefersLarger, useScalingFactor: false), effectiveParallelism)
            benchmark.measurement(.custom("Elapsed (ms)", polarity: .prefersSmaller, useScalingFactor: false), elapsedMs)
        }
    }

    Benchmark(
        "fuzz(Int) counting hook - iterations/sec",
        configuration: .init(
            metrics: [
                .custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false),
                .custom("Effective Parallelism (x100)", polarity: .prefersLarger, useScalingFactor: false),
                .custom("Elapsed (ms)", polarity: .prefersSmaller, useScalingFactor: false),
            ],
            warmupIterations: 0,
            scalingFactor: .one,
            maxDuration: .seconds(120),
            maxIterations: 25
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            let startCPU = getCPUTimeNanos()
            let startWall = DispatchTime.now().uptimeNanoseconds

            // Exercise the counting edge hook (8-bit saturating buckets) via a custom
            // strategy that records with it and adds every input — measures recording
            // throughput, which is what this benchmark targets.
            let result = try await fuzz(
                duration: .seconds(0.1),
                persistence: .replace,
                coverageStrategy: CoverageStrategy(edgeHook: countingEdgeHook) { sparse, corpus, input, schedule in
                    corpus.addEntry(input: input, scheduleBytes: schedule, sparse: sparse)
                    return true
                },
                parallelism: 16
            ) { (input: Int) in
                blackHole(input)
            }

            let endCPU = getCPUTimeNanos()
            let endWall = DispatchTime.now().uptimeNanoseconds

            let cpuDelta = endCPU - startCPU
            let wallDelta = endWall - startWall
            let effectiveParallelism = wallDelta > 0 ? Int((Double(cpuDelta) / Double(wallDelta)) * 100) : 100
            let wallSeconds = Double(wallDelta) / 1_000_000_000.0
            let iterationsPerSec = wallSeconds > 0 ? Int(Double(result.stats.totalInputs) / wallSeconds / 1000.0) : 0
            let elapsedMs = Int(wallDelta / 1_000_000)

            benchmark.measurement(.custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false), iterationsPerSec)
            benchmark.measurement(.custom("Effective Parallelism (x100)", polarity: .prefersLarger, useScalingFactor: false), effectiveParallelism)
            benchmark.measurement(.custom("Elapsed (ms)", polarity: .prefersSmaller, useScalingFactor: false), elapsedMs)
        }
    }

    Benchmark(
        "fuzz(Int) pathTrie strategy - iterations/sec",
        configuration: .init(
            metrics: [
                .custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false),
                .custom("Effective Parallelism (x100)", polarity: .prefersLarger, useScalingFactor: false),
                .custom("Elapsed (ms)", polarity: .prefersSmaller, useScalingFactor: false),
            ],
            warmupIterations: 0,
            scalingFactor: .one,
            maxDuration: .seconds(120),
            maxIterations: 25
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            let startCPU = getCPUTimeNanos()
            let startWall = DispatchTime.now().uptimeNanoseconds

            let result = try await fuzz(
                duration: .seconds(0.1),
                persistence: .replace,
                coverageStrategy: .pathTrie,
                parallelism: 16
            ) { (input: Int) in
                blackHole(input)
            }

            let endCPU = getCPUTimeNanos()
            let endWall = DispatchTime.now().uptimeNanoseconds

            let cpuDelta = endCPU - startCPU
            let wallDelta = endWall - startWall
            let effectiveParallelism = wallDelta > 0 ? Int((Double(cpuDelta) / Double(wallDelta)) * 100) : 100
            let wallSeconds = Double(wallDelta) / 1_000_000_000.0
            let iterationsPerSec = wallSeconds > 0 ? Int(Double(result.stats.totalInputs) / wallSeconds / 1000.0) : 0
            let elapsedMs = Int(wallDelta / 1_000_000)

            benchmark.measurement(.custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false), iterationsPerSec)
            benchmark.measurement(.custom("Effective Parallelism (x100)", polarity: .prefersLarger, useScalingFactor: false), effectiveParallelism)
            benchmark.measurement(.custom("Elapsed (ms)", polarity: .prefersSmaller, useScalingFactor: false), elapsedMs)
        }
    }

    Benchmark(
        "fuzz(Int) - 8 parallel runs, iterations/sec",
        configuration: .init(
            metrics: [
                .custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false),
                .custom("Effective Parallelism (x100)", polarity: .prefersLarger, useScalingFactor: false),
                .custom("Elapsed (ms)", polarity: .prefersSmaller, useScalingFactor: false),
            ],
            warmupIterations: 0,
            scalingFactor: .one,
            maxDuration: .seconds(120),
            maxIterations: 25
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            let startCPU = getCPUTimeNanos()
            let startWall = DispatchTime.now().uptimeNanoseconds

            let totalIterations = await withTaskGroup(of: Int.self, returning: Int.self) { group in
                for _ in 0..<8 {
                    group.addTask {
                        let result = try? await fuzz(
                            duration: .seconds(0.1),
                            persistence: .replace,
                            parallelism: 16
                        ) { (input: Int) in
                            blackHole(input)
                        }
                        return result?.stats.totalInputs ?? 0
                    }
                }
                return await group.reduce(0, +)
            }

            let endCPU = getCPUTimeNanos()
            let endWall = DispatchTime.now().uptimeNanoseconds

            let cpuDelta = endCPU - startCPU
            let wallDelta = endWall - startWall
            let effectiveParallelism = wallDelta > 0 ? Int((Double(cpuDelta) / Double(wallDelta)) * 100) : 100

            // Calculate iterations/sec based on actual wallclock time, divide by 1000 for (K) display
            let wallSeconds = Double(wallDelta) / 1_000_000_000.0
            let iterationsPerSec = wallSeconds > 0 ? Int(Double(totalIterations) / wallSeconds / 1000.0) : 0
            let elapsedMs = Int(wallDelta / 1_000_000)

            benchmark.measurement(.custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false), iterationsPerSec)
            benchmark.measurement(.custom("Effective Parallelism (x100)", polarity: .prefersLarger, useScalingFactor: false), effectiveParallelism)
            benchmark.measurement(.custom("Elapsed (ms)", polarity: .prefersSmaller, useScalingFactor: false), elapsedMs)
        }
    }

    Benchmark(
        "fuzz(Int) - 16 parallel runs, iterations/sec",
        configuration: .init(
            metrics: [
                .custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false),
                .custom("Effective Parallelism (x100)", polarity: .prefersLarger, useScalingFactor: false),
                .custom("Elapsed (ms)", polarity: .prefersSmaller, useScalingFactor: false),
            ],
            warmupIterations: 0,
            scalingFactor: .one,
            maxDuration: .seconds(120),
            maxIterations: 25
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            let startCPU = getCPUTimeNanos()
            let startWall = DispatchTime.now().uptimeNanoseconds

            let totalIterations = await withTaskGroup(of: Int.self, returning: Int.self) { group in
                for _ in 0..<16 {
                    group.addTask {
                        let result = try? await fuzz(
                            duration: .seconds(0.1),
                            persistence: .replace,
                            parallelism: 16
                        ) { (input: Int) in
                            blackHole(input)
                        }
                        return result?.stats.totalInputs ?? 0
                    }
                }
                return await group.reduce(0, +)
            }

            let endCPU = getCPUTimeNanos()
            let endWall = DispatchTime.now().uptimeNanoseconds

            let cpuDelta = endCPU - startCPU
            let wallDelta = endWall - startWall
            let effectiveParallelism = wallDelta > 0 ? Int((Double(cpuDelta) / Double(wallDelta)) * 100) : 100

            // Calculate iterations/sec based on actual wallclock time, divide by 1000 for (K) display
            let wallSeconds = Double(wallDelta) / 1_000_000_000.0
            let iterationsPerSec = wallSeconds > 0 ? Int(Double(totalIterations) / wallSeconds / 1000.0) : 0
            let elapsedMs = Int(wallDelta / 1_000_000)

            benchmark.measurement(.custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false), iterationsPerSec)
            benchmark.measurement(.custom("Effective Parallelism (x100)", polarity: .prefersLarger, useScalingFactor: false), effectiveParallelism)
            benchmark.measurement(.custom("Elapsed (ms)", polarity: .prefersSmaller, useScalingFactor: false), elapsedMs)
        }
    }

//    for p in 1...16 {
//        Benchmark(
//            "fuzz(Int) - iterations/sec p=\(p)",
//            configuration: .init(
//                metrics: [
//                    .custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false),
//                    .custom("Effective Parallelism (x100)", polarity: .prefersLarger, useScalingFactor: false),
//                ],
//                warmupIterations: 0,
//                scalingFactor: .one,
//                maxDuration: .seconds(120),
//                maxIterations: 20
//            )
//        ) { benchmark in
//            for _ in benchmark.scaledIterations {
//                let startCPU = getCPUTimeNanos()
//                let startWall = DispatchTime.now().uptimeNanoseconds
//
//                let result = try await fuzz(
//                    duration: .seconds(0.1),
//                    persistence: .replace,
//                    parallelism: p
//                ) { (input: Int) in
//                    blackHole(input)
//                }
//
//                let endCPU = getCPUTimeNanos()
//                let endWall = DispatchTime.now().uptimeNanoseconds
//
//                let cpuDelta = endCPU - startCPU
//                let wallDelta = endWall - startWall
//
//                // Effective parallelism = CPU time / wall time, multiplied by 100 for display precision
//                let effectiveParallelism = wallDelta > 0 ? Int((Double(cpuDelta) / Double(wallDelta)) * 100) : 100
//
//                // Multiply by 10 to convert 0.1s -> 1s, divide by 1000 for (K) display
//                benchmark.measurement(.custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false), result.stats.totalInputs / 100)
//                benchmark.measurement(.custom("Effective Parallelism (x100)", polarity: .prefersLarger, useScalingFactor: false), effectiveParallelism)
//            }
//        }
//    }
}
