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
import PropertyTestingKit

// MARK: - CPU Time Measurement

/// Returns total CPU time (user + system) in nanoseconds using getrusage
func getCPUTimeNanos() -> UInt64 {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let userNanos =
        UInt64(usage.ru_utime.tv_sec) * 1_000_000_000 + UInt64(usage.ru_utime.tv_usec) * 1000
    let systemNanos =
        UInt64(usage.ru_stime.tv_sec) * 1_000_000_000 + UInt64(usage.ru_stime.tv_usec) * 1000
    return userNanos + systemNanos
}

// MARK: - Comparison-dense workload

/// A comparison-heavy closure compiled with `-sanitize-coverage=…,trace-cmp`, so
/// each integer comparison below dispatches through `sancov_dispatch_cmp` into
/// the attached boundary observer. This isolates the per-comparison hot path
/// (dispatch → observer gate → `onCompare` → SyncBox lock → Dictionary update)
/// that the throughput rework targets. `CMP_PER_INPUT` controls the dispatch
/// volume per fuzz iteration; operands are deliberately near-boundary (differ by
/// 1) so the sign-mask path is exercised too.
let cmpPerInput = ProcessInfo.processInfo.environment["CMP_PER_INPUT"].flatMap(Int.init) ?? 256

@inline(never)
func comparisonDenseWork(_ input: Int) {
    var acc: UInt64 = 0
    var x = UInt64(bitPattern: Int64(input))
    for _ in 0..<cmpPerInput {
        // Two distinct comparison sites (PCs), both near-boundary (distance 1),
        // on data-dependent operands the optimizer can't fold.
        let y = x ^ 1
        if x < y { acc &+= 1 }                 // site A: |x-y| == 1
        if (x & 0xFF) < ((x &+ 1) & 0xFF) { acc &+= 2 }   // site B
        x = (x &* 6364136223846793005) &+ 1442695040888963407   // LCG step
    }
    blackHole(acc)
}

// MARK: - Test Function

/// PROFILE_STRATEGY selects the coverage strategy under profiling so the same
/// comparison-dense workload can be compared across arms (differential
/// attribution): "boundarydist" (default — the cmp hot path),
/// "newedge"/"pathtrie" (no cmp observer → the dispatch baseline).
let profileStrategy: CoverageStrategy = {
    switch ProcessInfo.processInfo.environment["PROFILE_STRATEGY"] {
    case "newedge": return .newEdge
    case "pathtrie": return .pathTrie
    case "boundarydist", nil: return .boundaryDistance
    default: return .boundaryDistance
    }
}()

/// Per-iteration fuzz duration (ms). Raise it (e.g. FUZZ_MS=400) for a long,
/// steady-state sampling window when recording with xctrace.
let fuzzMs = ProcessInfo.processInfo.environment["FUZZ_MS"].flatMap(Int.init) ?? 100

let benchmarks: @Sendable () -> Void = {
    Benchmark(
        "fuzz(Int) cmp-dense - iterations/sec",
        configuration: .init(
            metrics: [
                .custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false),
                .custom(
                    "Effective Parallelism (x100)", polarity: .prefersLarger,
                    useScalingFactor: false),
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
                duration: .milliseconds(fuzzMs), persistence: .replace, coverageStrategy: profileStrategy
            ) { (input: Int) in
                comparisonDenseWork(input)
            }

            let endCPU = getCPUTimeNanos()
            let endWall = DispatchTime.now().uptimeNanoseconds

            let cpuDelta = endCPU - startCPU
            let wallDelta = endWall - startWall
            let effectiveParallelism =
                wallDelta > 0 ? Int((Double(cpuDelta) / Double(wallDelta)) * 100) : 100

            // Calculate iterations/sec based on actual wallclock time, divide by 1000 for (K) display
            let wallSeconds = Double(wallDelta) / 1_000_000_000.0
            let iterationsPerSec =
                wallSeconds > 0 ? Int(Double(result.stats.totalInputs) / wallSeconds / 1000.0) : 0
            benchmark.measurement(
                .custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false),
                iterationsPerSec)
            benchmark.measurement(
                .custom(
                    "Effective Parallelism (x100)", polarity: .prefersLarger,
                    useScalingFactor: false), effectiveParallelism)
        }
    }
}
