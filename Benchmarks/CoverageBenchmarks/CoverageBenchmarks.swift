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

// MARK: - Benchmarks

let benchmarks: @Sendable () -> Void = {
    Benchmark(
        "fuzz(Int) - iterations/sec",
        configuration: .init(
            metrics: [
                .custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false),
                .custom("Effective Parallelism (x100)", polarity: .prefersLarger, useScalingFactor: false),
            ],
            warmupIterations: 0,
            scalingFactor: .one,
            maxDuration: .seconds(120),
            maxIterations: 100
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            let startCPU = getCPUTimeNanos()
            let startWall = DispatchTime.now().uptimeNanoseconds

            let result = try await fuzz(
                duration: .seconds(0.1),
                corpusMode: .refuzzReplace,
                parallelism: 8
            ) { (input: Int) in
                try parseAndValidate(input)
            }

            let endCPU = getCPUTimeNanos()
            let endWall = DispatchTime.now().uptimeNanoseconds

            let cpuDelta = endCPU - startCPU
            let wallDelta = endWall - startWall

            // Effective parallelism = CPU time / wall time, multiplied by 100 for display precision
            let effectiveParallelism = wallDelta > 0 ? Int((Double(cpuDelta) / Double(wallDelta)) * 100) : 100

            // Multiply by 10 to convert 0.1s -> 1s, divide by 1000 for (K) display
            benchmark.measurement(.custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false), result.stats.totalInputs / 100)
            benchmark.measurement(.custom("Effective Parallelism (x100)", polarity: .prefersLarger, useScalingFactor: false), effectiveParallelism)
        }
    }

    Benchmark(
        "fuzz(Int) - 8 parallel runs, iterations/sec",
        configuration: .init(
            metrics: [
                .custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false),
                .custom("Effective Parallelism (x100)", polarity: .prefersLarger, useScalingFactor: false),
            ],
            warmupIterations: 0,
            scalingFactor: .one,
            maxDuration: .seconds(120),
            maxIterations: 100
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
                            corpusMode: .refuzzReplace,
                            parallelism: 8
                        ) { (input: Int) in
                            try parseAndValidate(input)
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

            // Multiply by 10 to convert 0.1s -> 1s, divide by 1000 for (K) display
            benchmark.measurement(.custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false), totalIterations / 100)
            benchmark.measurement(.custom("Effective Parallelism (x100)", polarity: .prefersLarger, useScalingFactor: false), effectiveParallelism)
        }
    }

    Benchmark(
        "fuzz(Int) - 16 parallel runs, iterations/sec",
        configuration: .init(
            metrics: [
                .custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false),
                .custom("Effective Parallelism (x100)", polarity: .prefersLarger, useScalingFactor: false),
            ],
            warmupIterations: 0,
            scalingFactor: .one,
            maxDuration: .seconds(120),
            maxIterations: 100
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
                            corpusMode: .refuzzReplace,
                            parallelism: 8
                        ) { (input: Int) in
                            try parseAndValidate(input)
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

            // Multiply by 10 to convert 0.1s -> 1s, divide by 1000 for (K) display
            benchmark.measurement(.custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false), totalIterations / 100)
            benchmark.measurement(.custom("Effective Parallelism (x100)", polarity: .prefersLarger, useScalingFactor: false), effectiveParallelism)
        }
    }
}
