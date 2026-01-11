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
    Benchmark(
        "fuzz(Int, String, Bool, Double, UInt8) - 1000 iterations, with gap detection",
        configuration: .init(
            metrics: [.wallClock],
            warmupIterations: 0,
            scalingFactor: .one,
            maxDuration: .seconds(60),
            maxIterations: 1000
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
//            let _ = try? await fuzz(
//                iterations: 1000,
//                corpusMode: .refuzzReplace,
//                stoppingPlugins: [],
//                analysisPlugins: [.coverageGaps()]
//            ) { (i: Int, s: String, b: Bool, d: Double, u: UInt8) in
//                // Exercise all 5 inputs with branching logic
//                if i < 0 {
//                    blackHole(abs(i))
//                }
//                if s.isEmpty {
//                    blackHole("empty")
//                } else if s.count > 10 {
//                    blackHole(s.prefix(10))
//                }
//                if b {
//                    blackHole(d * 2)
//                } else {
//                    blackHole(d / 2)
//                }
//                if u > 128 {
//                    blackHole(u &- 128)
//                }
//            }
            cartesianProduct(
                Int.defaultMutator.seeds,
                String.defaultMutator.seeds,
                Bool.defaultMutator.seeds,
                Double.defaultMutator.seeds,
                UInt8.defaultMutator.seeds
            )
        }
    }
}
