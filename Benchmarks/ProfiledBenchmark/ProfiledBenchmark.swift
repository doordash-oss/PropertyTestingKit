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

///// A simple function to fuzz - parses an integer and checks bounds.
//func parseAndValidate(_ input: Int) throws {
//    if input == Int.min {
//        // Edge case handling
//    } else if input < 0 {
//        let _ = abs(input)
//    } else if input > 1000 {
//        let _ = input / 2
//    } else {
//        let _ = input * 2
//    }
//}

let benchmarks: @Sendable () -> Void = {
//    Benchmark(
//        "fuzz(Int, String, Bool, Double, UInt8) - 1000 iterations, with gap detection",
//        configuration: .init(
//            metrics: [.wallClock],
//            warmupIterations: 0,
//            scalingFactor: .one,
//            maxDuration: .seconds(60),
//            maxIterations: 1000
//        )
//    ) { benchmark in
//        for _ in benchmark.scaledIterations {
//            cartesianProduct(
//                Int.defaultMutator.seeds,
//                String.defaultMutator.seeds,
//                Bool.defaultMutator.seeds,
//                Double.defaultMutator.seeds,
//                UInt8.defaultMutator.seeds
//            )
//        }
//    }

    Benchmark(
        "ProfiledBenchmark",
        configuration: .init(
            metrics: [.custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false)],
            warmupIterations: 0,
            scalingFactor: .one,
            maxDuration: .seconds(120),
            maxIterations: 100
        )
    ) { benchmark in
        let config = FuzzEngine<String>.Config(
            maxDuration: .seconds(0.1),
            corpusMode: .refuzzReplace,
            plugins: [CoverageGapPlugin()]
        )
        let engine = FuzzEngine<String>(mutators: String.defaultMutator, config: config)
        for _ in benchmark.scaledIterations {
            let result = await engine.run { input in
                if input.isEmpty {
                    blackHole("empty")
                } else if input.count > 10 {
                    blackHole(input.prefix(10))
                } else {
                    blackHole(input)
                }
            }
            benchmark.measurement(.custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false), result.stats.totalInputs / 100)
        }
    }
}
