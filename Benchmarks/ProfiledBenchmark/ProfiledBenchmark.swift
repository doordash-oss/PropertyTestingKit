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
import ConcurrentQueues
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
    Benchmark(
        "fuzz(Int) - iterations/sec, refuzzReplace",
        configuration: .init(
            metrics: [.custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false)],
            warmupIterations: 0,
            scalingFactor: .one,
            maxDuration: .seconds(0.5),
            maxIterations: 100
        )
    ) { benchmark in
//        let config = FuzzEngine<Int>.Config(
//            maxDuration: .seconds(0.1),
//            corpusMode: .refuzzReplace
//        )
//        let engine = FuzzEngine<Int>(mutators: Int.defaultMutator, config: config)
        for _ in benchmark.scaledIterations {
//            let result = await engine.run { input in
//                try parseAndValidate(input)
//            }
            var count = 0
            while count < 1_000_000_000 {}

//            // Multiply by 10 to convert 0.1s -> 1s, divide by 1000 for (K) display
//            benchmark.measurement(.custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false), result.stats.totalInputs / 100)
        }
    }
}

