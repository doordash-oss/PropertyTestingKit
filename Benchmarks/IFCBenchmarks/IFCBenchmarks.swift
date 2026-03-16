//
//  IFCBenchmarks.swift
//  PropertyTestingKit
//
//  Realistic throughput benchmark using the IFC machine — a port of the
//  FuzzChick benchmark from Lampropoulos et al., OOPSLA 2019.
//
//  This measures fuzz iterations/sec on a real structured input type (Variation)
//  with a non-trivial test body (propSSNIHelper), giving a more realistic
//  performance baseline than the synthetic fuzz(Int)/blackHole benchmarks.
//
//  FuzzChick reference numbers (OOPSLA 2019, §4.1):
//    - FuzzChick (OCaml/QuickChick):  ~25,000 tests/sec
//    - QuickChick naive random:        ~82,000 tests/sec  (no coverage overhead)
//    - QcCrowbar (AFL backend):        ~16,500 tests/sec
//

import Benchmark
import Darwin
import Foundation
import IFCMachine
import PropertyTestingKit

let benchmarks: @Sendable () -> Void = {

    // MARK: - Realistic IFC throughput (single engine, default parallelism)

    Benchmark(
        "fuzz(Variation) SSNI check - iterations/sec",
        configuration: .init(
            metrics: [
                .custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false),
                .custom("Elapsed (ms)", polarity: .prefersSmaller, useScalingFactor: false),
            ],
            warmupIterations: 0,
            scalingFactor: .one,
            maxDuration: .seconds(300),
            maxIterations: 10
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            let startWall = DispatchTime.now().uptimeNanoseconds

            let result = try await fuzz(
                duration: .seconds(1),
                corpusMode: .refuzzReplace,
                makeHandlers: { [.energyMutation()] }
            ) { (variation: Variation) in
                blackHole(propSSNIHelper(table: .correct, variation: variation))
            }

            let endWall = DispatchTime.now().uptimeNanoseconds
            let wallDelta = endWall - startWall
            let wallSeconds = Double(wallDelta) / 1_000_000_000.0
            let iterationsPerSec = wallSeconds > 0 ? Int(Double(result.stats.totalInputs) / wallSeconds / 1000.0) : 0
            let elapsedMs = Int(wallDelta / 1_000_000)

            benchmark.measurement(.custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false), iterationsPerSec)
            benchmark.measurement(.custom("Elapsed (ms)", polarity: .prefersSmaller, useScalingFactor: false), elapsedMs)
        }
    }

    // // MARK: - IFC throughput with corpus mutation (for comparison)

    // Benchmark(
    //     "fuzz(Variation) SSNI check, corpusMutation - iterations/sec",
    //     configuration: .init(
    //         metrics: [
    //             .custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false),
    //             .custom("Elapsed (ms)", polarity: .prefersSmaller, useScalingFactor: false),
    //         ],
    //         warmupIterations: 0,
    //         scalingFactor: .one,
    //         maxDuration: .seconds(300),
    //         maxIterations: 10
    //     )
    // ) { benchmark in
    //     for _ in benchmark.scaledIterations {
    //         let startWall = DispatchTime.now().uptimeNanoseconds

    //         let result = try await fuzz(
    //             duration: .seconds(1),
    //             corpusMode: .refuzzReplace,
    //             makeHandlers: { [.corpusMutation()] }
    //         ) { (variation: Variation) in
    //             blackHole(propSSNIHelper(table: .correct, variation: variation))
    //         }

    //         let endWall = DispatchTime.now().uptimeNanoseconds
    //         let wallDelta = endWall - startWall
    //         let wallSeconds = Double(wallDelta) / 1_000_000_000.0
    //         let iterationsPerSec = wallSeconds > 0 ? Int(Double(result.stats.totalInputs) / wallSeconds / 1000.0) : 0
    //         let elapsedMs = Int(wallDelta / 1_000_000)

    //         benchmark.measurement(.custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false), iterationsPerSec)
    //         benchmark.measurement(.custom("Elapsed (ms)", polarity: .prefersSmaller, useScalingFactor: false), elapsedMs)
    //     }
    // }

    // // MARK: - IFC throughput, parallelism sweep

    // for parallelism in [1, 4, 8, 16] {
    //     Benchmark(
    //         "fuzz(Variation) SSNI check p=\(parallelism) - iterations/sec",
    //         configuration: .init(
    //             metrics: [
    //                 .custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false),
    //                 .custom("Elapsed (ms)", polarity: .prefersSmaller, useScalingFactor: false),
    //             ],
    //             warmupIterations: 0,
    //             scalingFactor: .one,
    //             maxDuration: .seconds(300),
    //             maxIterations: 10
    //         )
    //     ) { benchmark in
    //         for _ in benchmark.scaledIterations {
    //             let startWall = DispatchTime.now().uptimeNanoseconds

    //             let result = try await fuzz(
    //                 duration: .seconds(1),
    //                 corpusMode: .refuzzReplace,
    //                 parallelism: parallelism,
    //                 makeHandlers: { [.energyMutation()] }
    //             ) { (variation: Variation) in
    //                 blackHole(propSSNIHelper(table: .correct, variation: variation))
    //             }

    //             let endWall = DispatchTime.now().uptimeNanoseconds
    //             let wallDelta = endWall - startWall
    //             let wallSeconds = Double(wallDelta) / 1_000_000_000.0
    //             let iterationsPerSec = wallSeconds > 0 ? Int(Double(result.stats.totalInputs) / wallSeconds / 1000.0) : 0
    //             let elapsedMs = Int(wallDelta / 1_000_000)

    //             benchmark.measurement(.custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false), iterationsPerSec)
    //             benchmark.measurement(.custom("Elapsed (ms)", polarity: .prefersSmaller, useScalingFactor: false), elapsedMs)
    //         }
    //     }
    // }
}
