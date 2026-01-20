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

///// A simple function to fuzz - parses an integer and checks bounds.
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
        "KFIFOQueue.MPSC.Throughput",
        configuration: .init(
            metrics: [.custom("M ops/sec", polarity: .prefersLarger, useScalingFactor: false)],
            warmupIterations: 0,
            scalingFactor: .one,
            maxDuration: .seconds(60),
            maxIterations: 10
        )
    ) { benchmark in
        let producerCount = 4
        let messageCount = 10_000_000
        let messagesPerProducer = messageCount / producerCount

        for _ in benchmark.scaledIterations {
            let channel = KFIFOQueue<Int>(k: 8)
            let start = ContinuousClock.now

            await withTaskGroup(of: Void.self) { group in
                // Consumer
                group.addTask {
                    var received = 0
                    while received < messageCount {
                        if let _ = channel.dequeue() {
                            received += 1
                        }
                    }
                }

                // Producers
                for p in 0..<producerCount {
                    group.addTask {
                        let base = p * messagesPerProducer
                        for i in 0..<messagesPerProducer {
                            channel.enqueue(base + i)
                        }
                    }
                }

                await group.waitForAll()
            }

            let elapsed = ContinuousClock.now - start
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let opsPerSec = Double(messageCount) / seconds / 1_000_000
            benchmark.measurement(.custom("M ops/sec", polarity: .prefersLarger, useScalingFactor: false), Int(opsPerSec * 1000))
        }
    }
}

final class SyncBox<T>: @unchecked Sendable {
    private var storage: T
    private let lock = NSLock()

    /// Read or write the wrapped value in a thread-safe manner.
    var value: T {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storage = newValue
        }
    }

    init(_ value: T) {
        self.storage = value
    }

    /// Atomically update the value with a transform closure.
    @discardableResult
    func update<Result>(_ transform: (inout T) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try transform(&storage)
    }
}

