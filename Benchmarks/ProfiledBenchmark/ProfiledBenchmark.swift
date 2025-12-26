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

let benchmarks: @Sendable () -> Void = {
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
                plateauConfig: .init(enabled: false),
                corpusMode: .refuzzReplace,
                detectCoverageGaps: true
            )
            let engine = FuzzEngine<Int>(config: config)
            let _ = await engine.run { input in
                try parseAndValidate(input)
            }
        }
    }
}
