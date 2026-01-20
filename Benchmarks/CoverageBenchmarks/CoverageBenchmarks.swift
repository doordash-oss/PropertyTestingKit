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
        "fuzz(Int) - iterations/sec, refuzzReplace",
        configuration: .init(
            metrics: [.custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false)],
            warmupIterations: 0,
            scalingFactor: .one,
            maxDuration: .seconds(120),
            maxIterations: 100
        )
    ) { benchmark in
        let config = FuzzEngine<Int>.Config(
            maxDuration: .seconds(0.1),
            corpusMode: .refuzzReplace
        )
        let engine = FuzzEngine<Int>(mutators: Int.defaultMutator, config: config)
        for _ in benchmark.scaledIterations {
            let result = await engine.run { input in
                try parseAndValidate(input)
            }
            // Multiply by 10 to convert 0.1s -> 1s, divide by 1000 for (K) display
            benchmark.measurement(.custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false), result.stats.totalInputs / 100)
        }
    }

//    Benchmark(
//        "fuzz(Int) - iterations/sec, with gap detection",
//        configuration: .init(
//            metrics: [.custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false)],
//            warmupIterations: 0,
//            scalingFactor: .one,
//            maxDuration: .seconds(120),
//            maxIterations: 100
//        )
//    ) { benchmark in
//        let config = FuzzEngine<Int>.Config(
//            maxDuration: .seconds(0.1),
//            corpusMode: .refuzzReplace,
//            plugins: [CoverageGapPlugin()]
//        )
//        let engine = FuzzEngine<Int>(mutators: Int.defaultMutator, config: config)
//        for _ in benchmark.scaledIterations {
//            let result = await engine.run { input in
//                try parseAndValidate(input)
//            }
//            // Multiply by 10 to convert 0.1s -> 1s, divide by 1000 for (K) display
//            benchmark.measurement(.custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false), result.stats.totalInputs / 100)
//        }
//    }
//
//    Benchmark(
//        "fuzz(String) - iterations/sec, with gap detection (1 input)",
//        configuration: .init(
//            metrics: [.custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false)],
//            warmupIterations: 0,
//            scalingFactor: .one,
//            maxDuration: .seconds(120),
//            maxIterations: 100
//        )
//    ) { benchmark in
//        let config = FuzzEngine<String>.Config(
//            maxDuration: .seconds(0.1),
//            corpusMode: .refuzzReplace,
//            plugins: [CoverageGapPlugin()]
//        )
//        let engine = FuzzEngine<String>(mutators: String.defaultMutator, config: config)
//        for _ in benchmark.scaledIterations {
//            let result = await engine.run { input in
//                if input.isEmpty {
//                    blackHole("empty")
//                } else if input.count > 10 {
//                    blackHole(input.prefix(10))
//                }
//            }
//            benchmark.measurement(.custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false), result.stats.totalInputs / 100)
//        }
//    }
//
//    Benchmark(
//        "fuzz(Int, Int) - iterations/sec, with gap detection (2 inputs)",
//        configuration: .init(
//            metrics: [.custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false)],
//            warmupIterations: 0,
//            scalingFactor: .one,
//            maxDuration: .seconds(120),
//            maxIterations: 100
//        )
//    ) { benchmark in
//        for _ in benchmark.scaledIterations {
//            let result = try? await fuzz(
//                duration: .seconds(0.1),
//                corpusMode: .refuzzReplace,
//                plugins: [CoverageGapPlugin()]
//            ) { (i1: Int, i2: Int) in
//                if i1 < 0 {
//                    blackHole(i1.magnitude)
//                }
//                if i2 > 1000 {
//                    blackHole(i2 / 2)
//                }
//            }
//            if let result {
//                benchmark.measurement(.custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false), result.stats.totalInputs / 100)
//            }
//        }
//    }
//
//    Benchmark(
//        "fuzz(String, String) - iterations/sec, with gap detection (2 inputs)",
//        configuration: .init(
//            metrics: [.custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false)],
//            warmupIterations: 0,
//            scalingFactor: .one,
//            maxDuration: .seconds(120),
//            maxIterations: 100
//        )
//    ) { benchmark in
//        for _ in benchmark.scaledIterations {
//            let result = try? await fuzz(
//                duration: .seconds(0.1),
//                corpusMode: .refuzzReplace,
//                plugins: [CoverageGapPlugin()]
//            ) { (s1: String, s2: String) in
//                if s1.isEmpty {
//                    blackHole("empty1")
//                } else if s1.count > 10 {
//                    blackHole(s1.prefix(10))
//                }
//                if s2.isEmpty {
//                    blackHole("empty2")
//                } else if s2.count > 10 {
//                    blackHole(s2.prefix(10))
//                }
//            }
//            if let result {
//                benchmark.measurement(.custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false), result.stats.totalInputs / 100)
//            }
//        }
//    }
//
//    Benchmark(
//        "fuzz(Int, String) - iterations/sec, with gap detection (2 inputs)",
//        configuration: .init(
//            metrics: [.custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false)],
//            warmupIterations: 0,
//            scalingFactor: .one,
//            maxDuration: .seconds(120),
//            maxIterations: 100
//        )
//    ) { benchmark in
//        for _ in benchmark.scaledIterations {
//            let result = try? await fuzz(
//                duration: .seconds(0.1),
//                corpusMode: .refuzzReplace,
//                plugins: [CoverageGapPlugin()]
//            ) { (i: Int, s: String) in
//                if i < 0 {
//                    blackHole(i.magnitude)
//                }
//                if s.isEmpty {
//                    blackHole("empty")
//                } else if s.count > 10 {
//                    blackHole(s.prefix(10))
//                }
//            }
//            if let result {
//                benchmark.measurement(.custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false), result.stats.totalInputs / 100)
//            }
//        }
//    }
//
//    Benchmark(
//        "fuzz(Int, String, Bool) - iterations/sec, with gap detection (3 inputs)",
//        configuration: .init(
//            metrics: [.custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false)],
//            warmupIterations: 0,
//            scalingFactor: .one,
//            maxDuration: .seconds(120),
//            maxIterations: 100
//        )
//    ) { benchmark in
//        for _ in benchmark.scaledIterations {
//            let result = try? await fuzz(
//                duration: .seconds(0.1),
//                corpusMode: .refuzzReplace,
//                plugins: [CoverageGapPlugin()]
//            ) { (i: Int, s: String, b: Bool) in
//                if i < 0 {
//                    blackHole(i.magnitude)
//                }
//                if s.isEmpty {
//                    blackHole("empty")
//                } else if s.count > 10 {
//                    blackHole(s.prefix(10))
//                }
//                if b {
//                    blackHole("true")
//                }
//            }
//            if let result {
//                benchmark.measurement(.custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false), result.stats.totalInputs / 100)
//            }
//        }
//    }
//
//    Benchmark(
//        "fuzz(Int, String, Bool, Double) - iterations/sec, with gap detection (4 inputs)",
//        configuration: .init(
//            metrics: [.custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false)],
//            warmupIterations: 0,
//            scalingFactor: .one,
//            maxDuration: .seconds(120),
//            maxIterations: 100
//        )
//    ) { benchmark in
//        for _ in benchmark.scaledIterations {
//            let result = try? await fuzz(
//                duration: .seconds(0.1),
//                corpusMode: .refuzzReplace,
//                plugins: [CoverageGapPlugin()]
//            ) { (i: Int, s: String, b: Bool, d: Double) in
//                if i < 0 {
//                    blackHole(i.magnitude)
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
//            }
//            if let result {
//                benchmark.measurement(.custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false), result.stats.totalInputs / 100)
//            }
//        }
//    }
//
//    Benchmark(
//        "fuzz(Int, String, Bool, Double, UInt8) - iterations/sec, with gap detection (5 inputs)",
//        configuration: .init(
//            metrics: [.custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false)],
//            warmupIterations: 0,
//            scalingFactor: .one,
//            maxDuration: .seconds(120),
//            maxIterations: 100
//        )
//    ) { benchmark in
//        for _ in benchmark.scaledIterations {
//            let result = try? await fuzz(
//                duration: .seconds(0.1),
//                corpusMode: .refuzzReplace,
//                plugins: [CoverageGapPlugin()]
//            ) { (i: Int, s: String, b: Bool, d: Double, u: UInt8) in
//                // Exercise all 5 inputs with branching logic
//                if i < 0 {
//                    blackHole(i.magnitude)  // Use magnitude to avoid overflow on Int.min
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
//            if let result {
//                // Multiply by 10 to convert 0.1s -> 1s, divide by 1000 for (K) display
//                benchmark.measurement(.custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false), result.stats.totalInputs / 100)
//            }
//        }
//    }

    // Benchmark to test mutex contention with parallel fuzz engines
    Benchmark(
        "fuzz(Int) - 8 parallel engines, iterations/sec",
        configuration: .init(
            metrics: [.custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false)],
            warmupIterations: 0,
            scalingFactor: .one,
            maxDuration: .seconds(120),
            maxIterations: 100
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            let totalIterations = await withTaskGroup(of: Int.self, returning: Int.self) { group in
                for _ in 0..<8 {
                    group.addTask {
                        let config = FuzzEngine<Int>.Config(
                            maxDuration: .seconds(0.1),
                            corpusMode: .refuzzReplace
                        )
                        let engine = FuzzEngine<Int>(mutators: Int.defaultMutator, config: config)
                        let result = await engine.run { input in
                            try parseAndValidate(input)
                        }
                        return result.stats.totalInputs
                    }
                }
                return await group.reduce(0, +)
            }
            // Multiply by 10 to convert 0.1s -> 1s, divide by 1000 for (K) display
            benchmark.measurement(.custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false), totalIterations / 100)
        }
    }

    // Even more parallel engines to stress test
    Benchmark(
        "fuzz(Int) - 16 parallel engines, iterations/sec",
        configuration: .init(
            metrics: [.custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false)],
            warmupIterations: 0,
            scalingFactor: .one,
            maxDuration: .seconds(120),
            maxIterations: 100
        )
    ) { benchmark in
        for _ in benchmark.scaledIterations {
            let totalIterations = await withTaskGroup(of: Int.self, returning: Int.self) { group in
                for _ in 0..<16 {
                    group.addTask {
                        let config = FuzzEngine<Int>.Config(
                            maxDuration: .seconds(0.1),
                            corpusMode: .refuzzReplace
                        )
                        let engine = FuzzEngine<Int>(mutators: Int.defaultMutator, config: config)
                        let result = await engine.run { input in
                            try parseAndValidate(input)
                        }
                        return result.stats.totalInputs
                    }
                }
                return await group.reduce(0, +)
            }
            // Multiply by 10 to convert 0.1s -> 1s, divide by 1000 for (K) display
            benchmark.measurement(.custom("Iterations/sec (K)", polarity: .prefersLarger, useScalingFactor: false), totalIterations / 100)
        }
    }

}
