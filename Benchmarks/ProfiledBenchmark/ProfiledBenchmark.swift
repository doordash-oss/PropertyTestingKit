//
//  ProfiledBenchmark.swift
//  PropertyTestingKit
//
//  Performance benchmarks for profiling with Instruments.
//
//  Build with local toolchain: TOOLCHAINS=org.swift.local swift build -c release --product ProfiledBenchmark
//  Run: swift package benchmark
//

import Benchmark
import Darwin
import Foundation
import ConcurrentQueues
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

// MARK: - Test Function

let benchmarks: @Sendable () -> Void = {
    Benchmark(
        "fuzz(Int) - iterations/sec, refuzzReplace",
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

            let result = try await fuzz(duration: .seconds(0.1), corpusMode: .refuzzReplace) { (input: Int) in
                blackHole(input)
            }

            let endCPU = getCPUTimeNanos()
            let endWall = DispatchTime.now().uptimeNanoseconds

            let cpuDelta = endCPU - startCPU
            let wallDelta = endWall - startWall
            let effectiveParallelism = wallDelta > 0 ? Int((Double(cpuDelta) / Double(wallDelta)) * 100) : 100

            // Multiply by 10 to convert 0.1s -> 1s, divide by 1000 for (K) display
            benchmark.measurement(.custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false), result.stats.totalInputs / 100)
            benchmark.measurement(.custom("Effective Parallelism (x100)", polarity: .prefersLarger, useScalingFactor: false), effectiveParallelism)
        }
    }
}

