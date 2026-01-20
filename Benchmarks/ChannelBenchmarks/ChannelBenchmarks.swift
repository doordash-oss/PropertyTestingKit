//
//  ChannelBenchmarks.swift
//  PropertyTestingKit
//
//  Performance benchmarks for Channel operations.
//

import Benchmark
import Foundation
import ConcurrentQueues

let benchmarks: @Sendable () -> Void = {

//    // ============================================================
//    // MARK: - Async Channel Benchmarks
//    // ============================================================
//
//    // MARK: - Send Latency (no contention, large buffer)
//
//    Benchmark(
//        "AsyncChannel.Send.Latency",
//        configuration: .init(
//            metrics: [.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false)],
//            warmupIterations: 3,
//            scalingFactor: .one,
//            maxDuration: .seconds(30),
//            maxIterations: 20
//        )
//    ) { benchmark in
//        let iterations = 100_000
//        let channel = Channel<Int>(capacity: 131072)  // Large buffer
//
//        for _ in benchmark.scaledIterations {
//            let start = ContinuousClock.now
//
//            for i in 0..<iterations {
//                channel.send(i)
//            }
//
//            let elapsed = ContinuousClock.now - start
//            let nanoseconds = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
//            let nsPerOp = nanoseconds / Double(iterations)
//            benchmark.measurement(.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false), Int(nsPerOp))
//
//            // Drain
//            while channel.tryRecv() != nil {}
//        }
//    }
//
//    // MARK: - TryRecv Latency (data available)
//
//    Benchmark(
//        "AsyncChannel.TryRecv.Latency",
//        configuration: .init(
//            metrics: [.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false)],
//            warmupIterations: 3,
//            scalingFactor: .one,
//            maxDuration: .seconds(30),
//            maxIterations: 20
//        )
//    ) { benchmark in
//        let iterations = 100_000
//        let channel = Channel<Int>(capacity: 131072)
//
//        for _ in benchmark.scaledIterations {
//            // Fill
//            for i in 0..<iterations {
//                channel.send(i)
//            }
//
//            let start = ContinuousClock.now
//
//            var count = 0
//            while channel.tryRecv() != nil {
//                count += 1
//            }
//
//            let elapsed = ContinuousClock.now - start
//            let nanoseconds = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
//            let nsPerOp = nanoseconds / Double(count)
//            benchmark.measurement(.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false), Int(nsPerOp))
//        }
//    }
//
//    // MARK: - SPSC Throughput
//
//    Benchmark(
//        "AsyncChannel.SPSC.Throughput",
//        configuration: .init(
//            metrics: [.custom("M ops/sec", polarity: .prefersLarger, useScalingFactor: false)],
//            warmupIterations: 2,
//            scalingFactor: .one,
//            maxDuration: .seconds(60),
//            maxIterations: 5
//        )
//    ) { benchmark in
//        let messageCount = 1_000_000
//
//        for _ in benchmark.scaledIterations {
//            let channel = Channel<Int>(capacity: 4096)
//            let start = ContinuousClock.now
//
//            await withTaskGroup(of: Void.self) { group in
//                // Producer
//                group.addTask {
//                    for i in 0..<messageCount {
//                        channel.send(i)
//                    }
//                    channel.close()
//                }
//
//                // Consumer
//                group.addTask {
//                    var count = 0
//                    for await _ in channel {
//                        count += 1
//                    }
//                    blackHole(count)
//                }
//            }
//
//            let elapsed = ContinuousClock.now - start
//            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
//            let opsPerSec = Double(messageCount) / seconds / 1_000_000
//            benchmark.measurement(.custom("M ops/sec", polarity: .prefersLarger, useScalingFactor: false), Int(opsPerSec * 1000))
//        }
//    }
//
//    // MARK: - Round Trip Latency
//
//    Benchmark(
//        "AsyncChannel.RoundTrip.Latency",
//        configuration: .init(
//            metrics: [.custom("ns/roundtrip", polarity: .prefersSmaller, useScalingFactor: false)],
//            warmupIterations: 2,
//            scalingFactor: .one,
//            maxDuration: .seconds(60),
//            maxIterations: 5
//        )
//    ) { benchmark in
//        let iterations = 10_000
//
//        for _ in benchmark.scaledIterations {
//            let ping = Channel<Int>(capacity: 1)
//            let pong = Channel<Int>(capacity: 1)
//
//            let start = ContinuousClock.now
//
//            await withTaskGroup(of: Void.self) { group in
//                group.addTask {
//                    for i in 0..<iterations {
//                        ping.send(i)
//                        _ = await pong.recv()
//                    }
//                    ping.close()
//                }
//
//                group.addTask {
//                    for await value in ping {
//                        pong.send(value)
//                    }
//                    pong.close()
//                }
//            }
//
//            let elapsed = ContinuousClock.now - start
//            let nanoseconds = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
//            let nsPerRoundTrip = nanoseconds / Double(iterations)
//            benchmark.measurement(.custom("ns/roundtrip", polarity: .prefersSmaller, useScalingFactor: false), Int(nsPerRoundTrip))
//        }
//    }
//
//    // ============================================================
//    // MARK: - Sync Channel Benchmarks (semaphore-based blocking)
//    // ============================================================
//
//    Benchmark(
//        "SyncChannel.Send.Latency",
//        configuration: .init(
//            metrics: [.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false)],
//            warmupIterations: 3,
//            scalingFactor: .one,
//            maxDuration: .seconds(30),
//            maxIterations: 20
//        )
//    ) { benchmark in
//        let iterations = 100_000
//        let channel = SyncChannel<Int>(capacity: 131072)
//
//        for _ in benchmark.scaledIterations {
//            let start = ContinuousClock.now
//
//            for i in 0..<iterations {
//                channel.send(i)
//            }
//
//            let elapsed = ContinuousClock.now - start
//            let nanoseconds = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
//            let nsPerOp = nanoseconds / Double(iterations)
//            benchmark.measurement(.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false), Int(nsPerOp))
//
//            while channel.tryRecv() != nil {}
//        }
//    }
//
//    Benchmark(
//        "SyncChannel.TryRecv.Latency",
//        configuration: .init(
//            metrics: [.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false)],
//            warmupIterations: 3,
//            scalingFactor: .one,
//            maxDuration: .seconds(30),
//            maxIterations: 20
//        )
//    ) { benchmark in
//        let iterations = 100_000
//        let channel = SyncChannel<Int>(capacity: 131072)
//
//        for _ in benchmark.scaledIterations {
//            for i in 0..<iterations {
//                channel.send(i)
//            }
//
//            let start = ContinuousClock.now
//
//            var count = 0
//            while channel.tryRecv() != nil {
//                count += 1
//            }
//
//            let elapsed = ContinuousClock.now - start
//            let nanoseconds = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
//            let nsPerOp = nanoseconds / Double(count)
//            benchmark.measurement(.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false), Int(nsPerOp))
//        }
//    }
//
//    Benchmark(
//        "SyncChannel.SPSC.Throughput",
//        configuration: .init(
//            metrics: [.custom("M ops/sec", polarity: .prefersLarger, useScalingFactor: false)],
//            warmupIterations: 2,
//            scalingFactor: .one,
//            maxDuration: .seconds(60),
//            maxIterations: 5
//        )
//    ) { benchmark in
//        let messageCount = 1_000_000
//
//        for _ in benchmark.scaledIterations {
//            let channel = SyncChannel<Int>(capacity: 4096)
//            let start = ContinuousClock.now
//
//            // Use actual threads instead of async tasks
//            let producer = Thread {
//                for i in 0..<messageCount {
//                    channel.send(i)
//                }
//                channel.close()
//            }
//
//            var received = 0
//            let consumer = Thread {
//                for _ in channel {
//                    received += 1
//                }
//            }
//
//            producer.start()
//            consumer.start()
//
//            // Wait for threads to complete
//            while !producer.isFinished || !consumer.isFinished {
//                Thread.sleep(forTimeInterval: 0.001)
//            }
//
//            let elapsed = ContinuousClock.now - start
//            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
//            let opsPerSec = Double(messageCount) / seconds / 1_000_000
//            benchmark.measurement(.custom("M ops/sec", polarity: .prefersLarger, useScalingFactor: false), Int(opsPerSec * 1000))
//        }
//    }
//
//    Benchmark(
//        "SyncChannel.RoundTrip.Latency",
//        configuration: .init(
//            metrics: [.custom("ns/roundtrip", polarity: .prefersSmaller, useScalingFactor: false)],
//            warmupIterations: 2,
//            scalingFactor: .one,
//            maxDuration: .seconds(60),
//            maxIterations: 5
//        )
//    ) { benchmark in
//        let iterations = 10_000
//
//        for _ in benchmark.scaledIterations {
//            let ping = SyncChannel<Int>(capacity: 1)
//            let pong = SyncChannel<Int>(capacity: 1)
//
//            let start = ContinuousClock.now
//
//            let sender = Thread {
//                for i in 0..<iterations {
//                    ping.send(i)
//                    _ = pong.recv()
//                }
//                ping.close()
//            }
//
//            let responder = Thread {
//                for value in ping {
//                    pong.send(value)
//                }
//                pong.close()
//            }
//
//            sender.start()
//            responder.start()
//
//            while !sender.isFinished || !responder.isFinished {
//                Thread.sleep(forTimeInterval: 0.0001)
//            }
//
//            let elapsed = ContinuousClock.now - start
//            let nanoseconds = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
//            let nsPerRoundTrip = nanoseconds / Double(iterations)
//            benchmark.measurement(.custom("ns/roundtrip", polarity: .prefersSmaller, useScalingFactor: false), Int(nsPerRoundTrip))
//        }
//    }

//    // ============================================================
//    // MARK: - Spin Channel Benchmarks (busy-wait strategy)
//    // ============================================================
//
//    Benchmark(
//        "SpinChannel.Send.Latency",
//        configuration: .init(
//            metrics: [.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false)],
//            warmupIterations: 3,
//            scalingFactor: .one,
//            maxDuration: .seconds(30),
//            maxIterations: 20
//        )
//    ) { benchmark in
//        let iterations = 100_000
//        let channel = SpinChannel<Int>(capacity: 131072)
//
//        for _ in benchmark.scaledIterations {
//            let start = ContinuousClock.now
//
//            for i in 0..<iterations {
//                channel.send(i)
//            }
//
//            let elapsed = ContinuousClock.now - start
//            let nanoseconds = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
//            let nsPerOp = nanoseconds / Double(iterations)
//            benchmark.measurement(.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false), Int(nsPerOp))
//
//            while channel.tryRecv() != nil {}
//        }
//    }
//
//    Benchmark(
//        "SpinChannel.TryRecv.Latency",
//        configuration: .init(
//            metrics: [.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false)],
//            warmupIterations: 3,
//            scalingFactor: .one,
//            maxDuration: .seconds(30),
//            maxIterations: 20
//        )
//    ) { benchmark in
//        let iterations = 100_000
//        let channel = SpinChannel<Int>(capacity: 131072)
//
//        for _ in benchmark.scaledIterations {
//            for i in 0..<iterations {
//                channel.send(i)
//            }
//
//            let start = ContinuousClock.now
//
//            var count = 0
//            while channel.tryRecv() != nil {
//                count += 1
//            }
//
//            let elapsed = ContinuousClock.now - start
//            let nanoseconds = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
//            let nsPerOp = nanoseconds / Double(count)
//            benchmark.measurement(.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false), Int(nsPerOp))
//        }
//    }
//
//    Benchmark(
//        "SpinChannel.SPSC.Throughput",
//        configuration: .init(
//            metrics: [.custom("M ops/sec", polarity: .prefersLarger, useScalingFactor: false)],
//            warmupIterations: 2,
//            scalingFactor: .one,
//            maxDuration: .seconds(60),
//            maxIterations: 5
//        )
//    ) { benchmark in
//        let messageCount = 1_000_000
//
//        for _ in benchmark.scaledIterations {
//            let channel = SpinChannel<Int>(capacity: 4096)
//            let start = ContinuousClock.now
//
//            let producer = Thread {
//                for i in 0..<messageCount {
//                    channel.send(i)
//                }
//                channel.close()
//            }
//
//            var received = 0
//            let consumer = Thread {
//                for _ in channel {
//                    received += 1
//                }
//            }
//
//            producer.start()
//            consumer.start()
//
//            while !producer.isFinished || !consumer.isFinished {
//                Thread.sleep(forTimeInterval: 0.001)
//            }
//
//            let elapsed = ContinuousClock.now - start
//            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
//            let opsPerSec = Double(messageCount) / seconds / 1_000_000
//            benchmark.measurement(.custom("M ops/sec", polarity: .prefersLarger, useScalingFactor: false), Int(opsPerSec * 1000))
//        }
//    }
//
//    Benchmark(
//        "SpinChannel.RoundTrip.Latency",
//        configuration: .init(
//            metrics: [.custom("ns/roundtrip", polarity: .prefersSmaller, useScalingFactor: false)],
//            warmupIterations: 2,
//            scalingFactor: .one,
//            maxDuration: .seconds(60),
//            maxIterations: 5
//        )
//    ) { benchmark in
//        let iterations = 10_000
//
//        for _ in benchmark.scaledIterations {
//            let ping = SpinChannel<Int>(capacity: 1)
//            let pong = SpinChannel<Int>(capacity: 1)
//
//            let start = ContinuousClock.now
//
//            let sender = Thread {
//                for i in 0..<iterations {
//                    ping.send(i)
//                    _ = pong.recv()
//                }
//                ping.close()
//            }
//
//            let responder = Thread {
//                for value in ping {
//                    pong.send(value)
//                }
//                pong.close()
//            }
//
//            sender.start()
//            responder.start()
//
//            while !sender.isFinished || !responder.isFinished {
//                Thread.sleep(forTimeInterval: 0.0001)
//            }
//
//            let elapsed = ContinuousClock.now - start
//            let nanoseconds = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
//            let nsPerRoundTrip = nanoseconds / Double(iterations)
//            benchmark.measurement(.custom("ns/roundtrip", polarity: .prefersSmaller, useScalingFactor: false), Int(nsPerRoundTrip))
//        }
//    }

//    // ============================================================
//    // MARK: - Vyukov Channel Benchmarks (wait-free XCHG producers)
//    // ============================================================
//
//    Benchmark(
//        "VyukovChannel.Send.Latency",
//        configuration: .init(
//            metrics: [.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false)],
//            warmupIterations: 3,
//            scalingFactor: .one,
//            maxDuration: .seconds(30),
//            maxIterations: 20
//        )
//    ) { benchmark in
//        let iterations = 100_000
//
//        for _ in benchmark.scaledIterations {
//            let channel = VyukovChannel<Int>()
//
//            let start = ContinuousClock.now
//
//            for i in 0..<iterations {
//                channel.send(i)
//            }
//
//            let elapsed = ContinuousClock.now - start
//            let nanoseconds = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
//            let nsPerOp = nanoseconds / Double(iterations)
//            benchmark.measurement(.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false), Int(nsPerOp))
//
//            // Drain
//            while channel.tryRecv() != nil {}
//        }
//    }
//
//    Benchmark(
//        "VyukovChannel.TryRecv.Latency",
//        configuration: .init(
//            metrics: [.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false)],
//            warmupIterations: 3,
//            scalingFactor: .one,
//            maxDuration: .seconds(30),
//            maxIterations: 20
//        )
//    ) { benchmark in
//        let iterations = 100_000
//
//        for _ in benchmark.scaledIterations {
//            let channel = VyukovChannel<Int>()
//
//            // Fill
//            for i in 0..<iterations {
//                channel.send(i)
//            }
//
//            let start = ContinuousClock.now
//
//            var count = 0
//            while channel.tryRecv() != nil {
//                count += 1
//            }
//
//            let elapsed = ContinuousClock.now - start
//            let nanoseconds = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
//            let nsPerOp = nanoseconds / Double(count)
//            benchmark.measurement(.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false), Int(nsPerOp))
//        }
//    }
//
//    Benchmark(
//        "VyukovChannel.SPSC.Throughput",
//        configuration: .init(
//            metrics: [.custom("M ops/sec", polarity: .prefersLarger, useScalingFactor: false)],
//            warmupIterations: 2,
//            scalingFactor: .one,
//            maxDuration: .seconds(60),
//            maxIterations: 5
//        )
//    ) { benchmark in
//        let messageCount = 1_000_000
//
//        for _ in benchmark.scaledIterations {
//            let channel = VyukovChannel<Int>()
//            let start = ContinuousClock.now
//
//            let producer = Thread {
//                for i in 0..<messageCount {
//                    channel.send(i)
//                }
//                channel.close()
//            }
//
//            var received = 0
//            let consumer = Thread {
//                for _ in channel {
//                    received += 1
//                }
//            }
//
//            producer.start()
//            consumer.start()
//
//            while !producer.isFinished || !consumer.isFinished {
//                Thread.sleep(forTimeInterval: 0.001)
//            }
//
//            let elapsed = ContinuousClock.now - start
//            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
//            let opsPerSec = Double(messageCount) / seconds / 1_000_000
//            benchmark.measurement(.custom("M ops/sec", polarity: .prefersLarger, useScalingFactor: false), Int(opsPerSec * 1000))
//        }
//    }
//
//    Benchmark(
//        "VyukovChannel.RoundTrip.Latency",
//        configuration: .init(
//            metrics: [.custom("ns/roundtrip", polarity: .prefersSmaller, useScalingFactor: false)],
//            warmupIterations: 2,
//            scalingFactor: .one,
//            maxDuration: .seconds(60),
//            maxIterations: 5
//        )
//    ) { benchmark in
//        let iterations = 10_000
//
//        for _ in benchmark.scaledIterations {
//            let ping = VyukovChannel<Int>()
//            let pong = VyukovChannel<Int>()
//
//            let start = ContinuousClock.now
//
//            let sender = Thread {
//                for i in 0..<iterations {
//                    ping.send(i)
//                    _ = pong.recv()
//                }
//                ping.close()
//            }
//
//            let responder = Thread {
//                for value in ping {
//                    pong.send(value)
//                }
//                pong.close()
//            }
//
//            sender.start()
//            responder.start()
//
//            while !sender.isFinished || !responder.isFinished {
//                Thread.sleep(forTimeInterval: 0.0001)
//            }
//
//            let elapsed = ContinuousClock.now - start
//            let nanoseconds = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
//            let nsPerRoundTrip = nanoseconds / Double(iterations)
//            benchmark.measurement(.custom("ns/roundtrip", polarity: .prefersSmaller, useScalingFactor: false), Int(nsPerRoundTrip))
//        }
//    }

    // ============================================================
    // MARK: - Vyukov Bounded Channel Benchmarks (sequence number technique)
    // ============================================================

//    Benchmark(
//        "VyukovBoundedChannel.Send.Latency",
//        configuration: .init(
//            metrics: [.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false)],
//            warmupIterations: 3,
//            scalingFactor: .one,
//            maxDuration: .seconds(30),
//            maxIterations: 20
//        )
//    ) { benchmark in
//        let iterations = 100_000
//        let channel = VyukovBoundedChannel<Int>(capacity: 131072)
//
//        for _ in benchmark.scaledIterations {
//            let start = ContinuousClock.now
//
//            for i in 0..<iterations {
//                channel.send(i)
//            }
//
//            let elapsed = ContinuousClock.now - start
//            let nanoseconds = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
//            let nsPerOp = nanoseconds / Double(iterations)
//            benchmark.measurement(.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false), Int(nsPerOp))
//
//            while channel.tryRecv() != nil {}
//        }
//    }
//
//    Benchmark(
//        "VyukovBoundedChannel.TryRecv.Latency",
//        configuration: .init(
//            metrics: [.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false)],
//            warmupIterations: 3,
//            scalingFactor: .one,
//            maxDuration: .seconds(30),
//            maxIterations: 20
//        )
//    ) { benchmark in
//        let iterations = 100_000
//        let channel = VyukovBoundedChannel<Int>(capacity: 131072)
//
//        for _ in benchmark.scaledIterations {
//            for i in 0..<iterations {
//                channel.send(i)
//            }
//
//            let start = ContinuousClock.now
//
//            var count = 0
//            while channel.tryRecv() != nil {
//                count += 1
//            }
//
//            let elapsed = ContinuousClock.now - start
//            let nanoseconds = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
//            let nsPerOp = nanoseconds / Double(count)
//            benchmark.measurement(.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false), Int(nsPerOp))
//        }
//    }
//
//    Benchmark(
//        "VyukovBoundedChannel.SPSC.Throughput",
//        configuration: .init(
//            metrics: [.custom("M ops/sec", polarity: .prefersLarger, useScalingFactor: false)],
//            warmupIterations: 2,
//            scalingFactor: .one,
//            maxDuration: .seconds(60),
//            maxIterations: 5
//        )
//    ) { benchmark in
//        let messageCount = 1_000_000
//
//        for _ in benchmark.scaledIterations {
//            let channel = VyukovBoundedChannel<Int>(capacity: 4096)
//            let start = ContinuousClock.now
//
//            let producer = Thread {
//                for i in 0..<messageCount {
//                    channel.send(i)
//                }
//                channel.close()
//            }
//
//            var received = 0
//            let consumer = Thread {
//                for _ in channel {
//                    received += 1
//                }
//            }
//
//            producer.start()
//            consumer.start()
//
//            while !producer.isFinished || !consumer.isFinished {
//                Thread.sleep(forTimeInterval: 0.001)
//            }
//
//            let elapsed = ContinuousClock.now - start
//            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
//            let opsPerSec = Double(messageCount) / seconds / 1_000_000
//            benchmark.measurement(.custom("M ops/sec", polarity: .prefersLarger, useScalingFactor: false), Int(opsPerSec * 1000))
//        }
//    }
//
//    Benchmark(
//        "VyukovBoundedChannel.RoundTrip.Latency",
//        configuration: .init(
//            metrics: [.custom("ns/roundtrip", polarity: .prefersSmaller, useScalingFactor: false)],
//            warmupIterations: 2,
//            scalingFactor: .one,
//            maxDuration: .seconds(60),
//            maxIterations: 5
//        )
//    ) { benchmark in
//        let iterations = 10_000
//
//        for _ in benchmark.scaledIterations {
//            let ping = VyukovBoundedChannel<Int>(capacity: 1)
//            let pong = VyukovBoundedChannel<Int>(capacity: 1)
//
//            let start = ContinuousClock.now
//
//            let sender = Thread {
//                for i in 0..<iterations {
//                    ping.send(i)
//                    _ = pong.recv()
//                }
//                ping.close()
//            }
//
//            let responder = Thread {
//                for value in ping {
//                    pong.send(value)
//                }
//                pong.close()
//            }
//
//            sender.start()
//            responder.start()
//
//            while !sender.isFinished || !responder.isFinished {
//                Thread.sleep(forTimeInterval: 0.0001)
//            }
//
//            let elapsed = ContinuousClock.now - start
//            let nanoseconds = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
//            let nsPerRoundTrip = nanoseconds / Double(iterations)
//            benchmark.measurement(.custom("ns/roundtrip", polarity: .prefersSmaller, useScalingFactor: false), Int(nsPerRoundTrip))
//        }
//    }

    // ============================================================
    // MARK: - Relaxed Bounded Channel Benchmarks (out-of-order OK)
    // ============================================================

//    Benchmark(
//        "RelaxedBoundedChannel.Send.Latency",
//        configuration: .init(
//            metrics: [.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false)],
//            warmupIterations: 3,
//            scalingFactor: .one,
//            maxDuration: .seconds(30),
//            maxIterations: 20
//        )
//    ) { benchmark in
//        let iterations = 100_000
//        let channel = RelaxedBoundedChannel<Int>(capacity: 131072)
//
//        for _ in benchmark.scaledIterations {
//            let start = ContinuousClock.now
//
//            for i in 0..<iterations {
//                channel.send(i)
//            }
//
//            let elapsed = ContinuousClock.now - start
//            let nanoseconds = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
//            let nsPerOp = nanoseconds / Double(iterations)
//            benchmark.measurement(.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false), Int(nsPerOp))
//
//            while channel.tryRecv() != nil {}
//        }
//    }
//
//    Benchmark(
//        "RelaxedBoundedChannel.TryRecv.Latency",
//        configuration: .init(
//            metrics: [.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false)],
//            warmupIterations: 3,
//            scalingFactor: .one,
//            maxDuration: .seconds(30),
//            maxIterations: 20
//        )
//    ) { benchmark in
//        let iterations = 100_000
//        let channel = RelaxedBoundedChannel<Int>(capacity: 131072)
//
//        for _ in benchmark.scaledIterations {
//            for i in 0..<iterations {
//                channel.send(i)
//            }
//
//            let start = ContinuousClock.now
//
//            var count = 0
//            while channel.tryRecv() != nil {
//                count += 1
//            }
//
//            let elapsed = ContinuousClock.now - start
//            let nanoseconds = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
//            let nsPerOp = nanoseconds / Double(count)
//            benchmark.measurement(.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false), Int(nsPerOp))
//        }
//    }
//
//    Benchmark(
//        "RelaxedBoundedChannel.SPSC.Throughput",
//        configuration: .init(
//            metrics: [.custom("M ops/sec", polarity: .prefersLarger, useScalingFactor: false)],
//            warmupIterations: 2,
//            scalingFactor: .one,
//            maxDuration: .seconds(60),
//            maxIterations: 5
//        )
//    ) { benchmark in
//        let messageCount = 1_000_000
//
//        for _ in benchmark.scaledIterations {
//            let channel = RelaxedBoundedChannel<Int>(capacity: 4096)
//            let start = ContinuousClock.now
//
//            let producer = Thread {
//                for i in 0..<messageCount {
//                    channel.send(i)
//                }
//                channel.close()
//            }
//
//            var received = 0
//            let consumer = Thread {
//                for _ in channel {
//                    received += 1
//                }
//            }
//
//            producer.start()
//            consumer.start()
//
//            while !producer.isFinished || !consumer.isFinished {
//                Thread.sleep(forTimeInterval: 0.001)
//            }
//
//            let elapsed = ContinuousClock.now - start
//            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
//            let opsPerSec = Double(messageCount) / seconds / 1_000_000
//            benchmark.measurement(.custom("M ops/sec", polarity: .prefersLarger, useScalingFactor: false), Int(opsPerSec * 1000))
//        }
//    }
//
//    Benchmark(
//        "RelaxedBoundedChannel.RoundTrip.Latency",
//        configuration: .init(
//            metrics: [.custom("ns/roundtrip", polarity: .prefersSmaller, useScalingFactor: false)],
//            warmupIterations: 2,
//            scalingFactor: .one,
//            maxDuration: .seconds(60),
//            maxIterations: 5
//        )
//    ) { benchmark in
//        let iterations = 10_000
//
//        for _ in benchmark.scaledIterations {
//            let ping = RelaxedBoundedChannel<Int>(capacity: 1)
//            let pong = RelaxedBoundedChannel<Int>(capacity: 1)
//
//            let start = ContinuousClock.now
//
//            let sender = Thread {
//                for i in 0..<iterations {
//                    ping.send(i)
//                    _ = pong.recv()
//                }
//                ping.close()
//            }
//
//            let responder = Thread {
//                for value in ping {
//                    pong.send(value)
//                }
//                pong.close()
//            }
//
//            sender.start()
//            responder.start()
//
//            while !sender.isFinished || !responder.isFinished {
//                Thread.sleep(forTimeInterval: 0.0001)
//            }
//
//            let elapsed = ContinuousClock.now - start
//            let nanoseconds = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
//            let nsPerRoundTrip = nanoseconds / Double(iterations)
//            benchmark.measurement(.custom("ns/roundtrip", polarity: .prefersSmaller, useScalingFactor: false), Int(nsPerRoundTrip))
//        }
//    }

    // MARK: - MPSC Contention Benchmark (where relaxed ordering shines)

//    Benchmark(
//        "RelaxedBoundedChannel.MPSC.Contention",
//        configuration: .init(
//            metrics: [.custom("M ops/sec", polarity: .prefersLarger, useScalingFactor: false)],
//            warmupIterations: 2,
//            scalingFactor: .one,
//            maxDuration: .seconds(60),
//            maxIterations: 5
//        )
//    ) { benchmark in
//        let producerCount = 4
//        let messagesPerProducer = 250_000
//
//        for _ in benchmark.scaledIterations {
//            let channel = RelaxedBoundedChannel<Int>(capacity: 4096)
//            let producersDone = UnsafeMutablePointer<Int>.allocate(capacity: 1)
//            producersDone.initialize(to: 0)
//            defer { producersDone.deallocate() }
//
//            let start = ContinuousClock.now
//
//            var producers: [Thread] = []
//            for p in 0..<producerCount {
//                let producer = Thread {
//                    let base = p * messagesPerProducer
//                    for i in 0..<messagesPerProducer {
//                        channel.send(base + i)
//                    }
//                    producersDone.pointee += 1
//                }
//                producers.append(producer)
//            }
//
//            var received = 0
//            let consumer = Thread {
//                // Consume until all producers done and channel empty
//                while producersDone.pointee < producerCount || channel.tryRecv() != nil {
//                    if channel.tryRecv() != nil {
//                        received += 1
//                    }
//                }
//                // Final drain
//                while channel.tryRecv() != nil {
//                    received += 1
//                }
//            }
//
//            for p in producers { p.start() }
//            consumer.start()
//
//            for p in producers {
//                while !p.isFinished { Thread.sleep(forTimeInterval: 0.001) }
//            }
//            channel.close()
//            while !consumer.isFinished { Thread.sleep(forTimeInterval: 0.001) }
//
//            let elapsed = ContinuousClock.now - start
//            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
//            let totalMessages = producerCount * messagesPerProducer
//            let opsPerSec = Double(totalMessages) / seconds / 1_000_000
//            benchmark.measurement(.custom("M ops/sec", polarity: .prefersLarger, useScalingFactor: false), Int(opsPerSec * 1000))
//        }
//    }
//
//    // Same benchmark for VyukovBoundedChannel for comparison
//    Benchmark(
//        "VyukovBoundedChannel.MPSC.Contention",
//        configuration: .init(
//            metrics: [.custom("M ops/sec", polarity: .prefersLarger, useScalingFactor: false)],
//            warmupIterations: 2,
//            scalingFactor: .one,
//            maxDuration: .seconds(60),
//            maxIterations: 5
//        )
//    ) { benchmark in
//        let producerCount = 4
//        let messagesPerProducer = 250_000
//
//        for _ in benchmark.scaledIterations {
//            let channel = VyukovBoundedChannel<Int>(capacity: 4096)
//            let producersDone = UnsafeMutablePointer<Int>.allocate(capacity: 1)
//            producersDone.initialize(to: 0)
//            defer { producersDone.deallocate() }
//
//            let start = ContinuousClock.now
//
//            var producers: [Thread] = []
//            for p in 0..<producerCount {
//                let producer = Thread {
//                    let base = p * messagesPerProducer
//                    for i in 0..<messagesPerProducer {
//                        channel.send(base + i)
//                    }
//                    producersDone.pointee += 1
//                }
//                producers.append(producer)
//            }
//
//            var received = 0
//            let consumer = Thread {
//                // Consume until all producers done and channel empty
//                while producersDone.pointee < producerCount || channel.tryRecv() != nil {
//                    if channel.tryRecv() != nil {
//                        received += 1
//                    }
//                }
//                // Final drain
//                while channel.tryRecv() != nil {
//                    received += 1
//                }
//            }
//
//            for p in producers { p.start() }
//            consumer.start()
//
//            for p in producers {
//                while !p.isFinished { Thread.sleep(forTimeInterval: 0.001) }
//            }
//            channel.close()
//            while !consumer.isFinished { Thread.sleep(forTimeInterval: 0.001) }
//
//            let elapsed = ContinuousClock.now - start
//            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
//            let totalMessages = producerCount * messagesPerProducer
//            let opsPerSec = Double(totalMessages) / seconds / 1_000_000
//            benchmark.measurement(.custom("M ops/sec", polarity: .prefersLarger, useScalingFactor: false), Int(opsPerSec * 1000))
//        }
//    }

    // ============================================================
    // MARK: - KFifoQueue Benchmarks (bounded out-of-order k-FIFO)
    // ============================================================

//    Benchmark(
//        "KFifoQueue.Send.Latency",
//        configuration: .init(
//            metrics: [.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false)],
//            warmupIterations: 3,
//            scalingFactor: .one,
//            maxDuration: .seconds(30),
//            maxIterations: 20
//        )
//    ) { benchmark in
//        let iterations = 100_000
//        let channel = KFifoQueue<Int>(k: 8, capacity: 131072)
//
//        for _ in benchmark.scaledIterations {
//            let start = ContinuousClock.now
//
//            for i in 0..<iterations {
//                channel.send(i)
//            }
//
//            let elapsed = ContinuousClock.now - start
//            let nanoseconds = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
//            let nsPerOp = nanoseconds / Double(iterations)
//            benchmark.measurement(.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false), Int(nsPerOp))
//
//            while channel.tryRecv() != nil {}
//        }
//    }
//
//    Benchmark(
//        "KFifoQueue.TryRecv.Latency",
//        configuration: .init(
//            metrics: [.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false)],
//            warmupIterations: 3,
//            scalingFactor: .one,
//            maxDuration: .seconds(30),
//            maxIterations: 20
//        )
//    ) { benchmark in
//        let iterations = 100_000
//        let channel = KFifoQueue<Int>(k: 8, capacity: 131072)
//
//        for _ in benchmark.scaledIterations {
//            for i in 0..<iterations {
//                channel.send(i)
//            }
//
//            let start = ContinuousClock.now
//
//            var count = 0
//            while channel.tryRecv() != nil {
//                count += 1
//            }
//
//            let elapsed = ContinuousClock.now - start
//            let nanoseconds = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
//            let nsPerOp = nanoseconds / Double(count)
//            benchmark.measurement(.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false), Int(nsPerOp))
//        }
//    }
//
//    Benchmark(
//        "KFifoQueue.SPSC.Throughput",
//        configuration: .init(
//            metrics: [.custom("M ops/sec", polarity: .prefersLarger, useScalingFactor: false)],
//            warmupIterations: 2,
//            scalingFactor: .one,
//            maxDuration: .seconds(60),
//            maxIterations: 5
//        )
//    ) { benchmark in
//        let messageCount = 1_000_000
//
//        for _ in benchmark.scaledIterations {
//            let channel = KFifoQueue<Int>(k: 8, capacity: 4096)
//            let start = ContinuousClock.now
//
//            let producer = Thread {
//                for i in 0..<messageCount {
//                    channel.send(i)
//                }
//                channel.close()
//            }
//
//            var received = 0
//            let consumer = Thread {
//                for _ in channel {
//                    received += 1
//                }
//            }
//
//            producer.start()
//            consumer.start()
//
//            while !producer.isFinished { Thread.sleep(forTimeInterval: 0.001) }
//            while !consumer.isFinished { Thread.sleep(forTimeInterval: 0.001) }
//
//            let elapsed = ContinuousClock.now - start
//            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
//            let opsPerSec = Double(received) / seconds / 1_000_000
//            benchmark.measurement(.custom("M ops/sec", polarity: .prefersLarger, useScalingFactor: false), Int(opsPerSec * 1000))
//        }
//    }
//
//    Benchmark(
//        "KFifoQueue.MPSC.Contention",
//        configuration: .init(
//            metrics: [.custom("M ops/sec", polarity: .prefersLarger, useScalingFactor: false)],
//            warmupIterations: 2,
//            scalingFactor: .one,
//            maxDuration: .seconds(60),
//            maxIterations: 5
//        )
//    ) { benchmark in
//        let producerCount = 4
//        let messagesPerProducer = 250_000
//
//        for _ in benchmark.scaledIterations {
//            let channel = KFifoQueue<Int>(k: 8, capacity: 4096)
//            let producersDone = UnsafeMutablePointer<Int>.allocate(capacity: 1)
//            producersDone.initialize(to: 0)
//            defer { producersDone.deallocate() }
//
//            let start = ContinuousClock.now
//
//            var producers: [Thread] = []
//            for p in 0..<producerCount {
//                let producer = Thread {
//                    let base = p * messagesPerProducer
//                    for i in 0..<messagesPerProducer {
//                        channel.send(base + i)
//                    }
//                    producersDone.pointee += 1
//                }
//                producers.append(producer)
//            }
//
//            var received = 0
//            let consumer = Thread {
//                while producersDone.pointee < producerCount || channel.tryRecv() != nil {
//                    if channel.tryRecv() != nil {
//                        received += 1
//                    }
//                }
//                while channel.tryRecv() != nil {
//                    received += 1
//                }
//            }
//
//            for p in producers { p.start() }
//            consumer.start()
//
//            for p in producers {
//                while !p.isFinished { Thread.sleep(forTimeInterval: 0.001) }
//            }
//            channel.close()
//            while !consumer.isFinished { Thread.sleep(forTimeInterval: 0.001) }
//
//            let elapsed = ContinuousClock.now - start
//            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
//            let totalMessages = producerCount * messagesPerProducer
//            let opsPerSec = Double(totalMessages) / seconds / 1_000_000
//            benchmark.measurement(.custom("M ops/sec", polarity: .prefersLarger, useScalingFactor: false), Int(opsPerSec * 1000))
//        }
//    }
//
//    Benchmark(
//        "KFifoQueue.RoundTrip.Latency",
//        configuration: .init(
//            metrics: [.custom("ns/roundtrip", polarity: .prefersSmaller, useScalingFactor: false)],
//            warmupIterations: 2,
//            scalingFactor: .one,
//            maxDuration: .seconds(60),
//            maxIterations: 5
//        )
//    ) { benchmark in
//        let iterations = 10_000
//
//        for _ in benchmark.scaledIterations {
//            let ping = KFifoQueue<Int>(k: 8, capacity: 1024)
//            let pong = KFifoQueue<Int>(k: 8, capacity: 1024)
//
//            let start = ContinuousClock.now
//
//            let sender = Thread {
//                for i in 0..<iterations {
//                    ping.send(i)
//                    _ = pong.recv()
//                }
//                ping.close()
//            }
//
//            let responder = Thread {
//                for value in ping {
//                    pong.send(value)
//                }
//                pong.close()
//            }
//
//            sender.start()
//            responder.start()
//
//            while !sender.isFinished || !responder.isFinished {
//                Thread.sleep(forTimeInterval: 0.0001)
//            }
//
//            let elapsed = ContinuousClock.now - start
//            let nanoseconds = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
//            let nsPerRoundTrip = nanoseconds / Double(iterations)
//            benchmark.measurement(.custom("ns/roundtrip", polarity: .prefersSmaller, useScalingFactor: false), Int(nsPerRoundTrip))
//        }
//    }

    // ============================================================
    // MARK: - MultiQueue Benchmarks (distributed partial queues)
    // ============================================================

//    Benchmark(
//        "MultiQueue.Send.Latency",
//        configuration: .init(
//            metrics: [.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false)],
//            warmupIterations: 3,
//            scalingFactor: .one,
//            maxDuration: .seconds(30),
//            maxIterations: 20
//        )
//    ) { benchmark in
//        let iterations = 100_000
//        let channel = MultiQueue<Int>(queueCount: 8, partialCapacity: 16384)
//
//        for _ in benchmark.scaledIterations {
//            let start = ContinuousClock.now
//
//            for i in 0..<iterations {
//                channel.send(i)
//            }
//
//            let elapsed = ContinuousClock.now - start
//            let nanoseconds = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
//            let nsPerOp = nanoseconds / Double(iterations)
//            benchmark.measurement(.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false), Int(nsPerOp))
//
//            while channel.tryRecv() != nil {}
//        }
//    }
//
//    Benchmark(
//        "MultiQueue.TryRecv.Latency",
//        configuration: .init(
//            metrics: [.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false)],
//            warmupIterations: 3,
//            scalingFactor: .one,
//            maxDuration: .seconds(30),
//            maxIterations: 20
//        )
//    ) { benchmark in
//        let iterations = 100_000
//        let channel = MultiQueue<Int>(queueCount: 8, partialCapacity: 16384)
//
//        for _ in benchmark.scaledIterations {
//            for i in 0..<iterations {
//                channel.send(i)
//            }
//
//            let start = ContinuousClock.now
//
//            var count = 0
//            while channel.tryRecv() != nil {
//                count += 1
//            }
//
//            let elapsed = ContinuousClock.now - start
//            let nanoseconds = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
//            let nsPerOp = nanoseconds / Double(count)
//            benchmark.measurement(.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false), Int(nsPerOp))
//        }
//    }
//
//    Benchmark(
//        "MultiQueue.SPSC.Throughput",
//        configuration: .init(
//            metrics: [.custom("M ops/sec", polarity: .prefersLarger, useScalingFactor: false)],
//            warmupIterations: 2,
//            scalingFactor: .one,
//            maxDuration: .seconds(60),
//            maxIterations: 5
//        )
//    ) { benchmark in
//        let messageCount = 1_000_000
//
//        for _ in benchmark.scaledIterations {
//            let channel = MultiQueue<Int>(queueCount: 8, partialCapacity: 512)
//            let start = ContinuousClock.now
//
//            let producer = Thread {
//                for i in 0..<messageCount {
//                    channel.send(i)
//                }
//                channel.close()
//            }
//
//            var received = 0
//            let consumer = Thread {
//                for _ in channel {
//                    received += 1
//                }
//            }
//
//            producer.start()
//            consumer.start()
//
//            while !producer.isFinished { Thread.sleep(forTimeInterval: 0.001) }
//            while !consumer.isFinished { Thread.sleep(forTimeInterval: 0.001) }
//
//            let elapsed = ContinuousClock.now - start
//            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
//            let opsPerSec = Double(received) / seconds / 1_000_000
//            benchmark.measurement(.custom("M ops/sec", polarity: .prefersLarger, useScalingFactor: false), Int(opsPerSec * 1000))
//        }
//    }
//
//    Benchmark(
//        "MultiQueue.MPSC.Contention",
//        configuration: .init(
//            metrics: [.custom("M ops/sec", polarity: .prefersLarger, useScalingFactor: false)],
//            warmupIterations: 2,
//            scalingFactor: .one,
//            maxDuration: .seconds(60),
//            maxIterations: 5
//        )
//    ) { benchmark in
//        let producerCount = 4
//        let messagesPerProducer = 250_000
//
//        for _ in benchmark.scaledIterations {
//            let channel = MultiQueue<Int>(queueCount: 8, partialCapacity: 512)
//            let producersDone = UnsafeMutablePointer<Int>.allocate(capacity: 1)
//            producersDone.initialize(to: 0)
//            defer { producersDone.deallocate() }
//
//            let start = ContinuousClock.now
//
//            var producers: [Thread] = []
//            for p in 0..<producerCount {
//                let producer = Thread {
//                    let base = p * messagesPerProducer
//                    for i in 0..<messagesPerProducer {
//                        channel.send(base + i)
//                    }
//                    producersDone.pointee += 1
//                }
//                producers.append(producer)
//            }
//
//            var received = 0
//            let consumer = Thread {
//                while producersDone.pointee < producerCount || channel.tryRecv() != nil {
//                    if channel.tryRecv() != nil {
//                        received += 1
//                    }
//                }
//                while channel.tryRecv() != nil {
//                    received += 1
//                }
//            }
//
//            for p in producers { p.start() }
//            consumer.start()
//
//            for p in producers {
//                while !p.isFinished { Thread.sleep(forTimeInterval: 0.001) }
//            }
//            channel.close()
//            while !consumer.isFinished { Thread.sleep(forTimeInterval: 0.001) }
//
//            let elapsed = ContinuousClock.now - start
//            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
//            let totalMessages = producerCount * messagesPerProducer
//            let opsPerSec = Double(totalMessages) / seconds / 1_000_000
//            benchmark.measurement(.custom("M ops/sec", polarity: .prefersLarger, useScalingFactor: false), Int(opsPerSec * 1000))
//        }
//    }
//
//    Benchmark(
//        "MultiQueue.RoundTrip.Latency",
//        configuration: .init(
//            metrics: [.custom("ns/roundtrip", polarity: .prefersSmaller, useScalingFactor: false)],
//            warmupIterations: 2,
//            scalingFactor: .one,
//            maxDuration: .seconds(60),
//            maxIterations: 5
//        )
//    ) { benchmark in
//        let iterations = 10_000
//
//        for _ in benchmark.scaledIterations {
//            let ping = MultiQueue<Int>(queueCount: 8, partialCapacity: 1024)
//            let pong = MultiQueue<Int>(queueCount: 8, partialCapacity: 1024)
//
//            let start = ContinuousClock.now
//
//            let sender = Thread {
//                for i in 0..<iterations {
//                    ping.send(i)
//                    _ = pong.recv()
//                }
//                ping.close()
//            }
//
//            let responder = Thread {
//                for value in ping {
//                    pong.send(value)
//                }
//                pong.close()
//            }
//
//            sender.start()
//            responder.start()
//
//            while !sender.isFinished || !responder.isFinished {
//                Thread.sleep(forTimeInterval: 0.0001)
//            }
//
//            let elapsed = ContinuousClock.now - start
//            let nanoseconds = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
//            let nsPerRoundTrip = nanoseconds / Double(iterations)
//            benchmark.measurement(.custom("ns/roundtrip", polarity: .prefersSmaller, useScalingFactor: false), Int(nsPerRoundTrip))
//        }
//    }

    // ============================================================
    // MARK: - RCQSQueue Benchmarks (two-phase slot assignment)
    // ============================================================

//    Benchmark(
//        "RCQSQueue.Send.Latency",
//        configuration: .init(
//            metrics: [.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false)],
//            warmupIterations: 3,
//            scalingFactor: .one,
//            maxDuration: .seconds(30),
//            maxIterations: 20
//        )
//    ) { benchmark in
//        let iterations = 100_000
//        let channel = RCQSQueue<Int>(capacity: 131072)
//
//        for _ in benchmark.scaledIterations {
//            let start = ContinuousClock.now
//
//            for i in 0..<iterations {
//                channel.send(i)
//            }
//
//            let elapsed = ContinuousClock.now - start
//            let nanoseconds = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
//            let nsPerOp = nanoseconds / Double(iterations)
//            benchmark.measurement(.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false), Int(nsPerOp))
//
//            while channel.tryRecv() != nil {}
//        }
//    }
//
//    Benchmark(
//        "RCQSQueue.TryRecv.Latency",
//        configuration: .init(
//            metrics: [.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false)],
//            warmupIterations: 3,
//            scalingFactor: .one,
//            maxDuration: .seconds(30),
//            maxIterations: 20
//        )
//    ) { benchmark in
//        let iterations = 100_000
//        let channel = RCQSQueue<Int>(capacity: 131072)
//
//        for _ in benchmark.scaledIterations {
//            for i in 0..<iterations {
//                channel.send(i)
//            }
//
//            let start = ContinuousClock.now
//
//            var count = 0
//            while channel.tryRecv() != nil {
//                count += 1
//            }
//
//            let elapsed = ContinuousClock.now - start
//            let nanoseconds = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
//            let nsPerOp = nanoseconds / Double(count)
//            benchmark.measurement(.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false), Int(nsPerOp))
//        }
//    }
//
//    Benchmark(
//        "RCQSQueue.SPSC.Throughput",
//        configuration: .init(
//            metrics: [.custom("M ops/sec", polarity: .prefersLarger, useScalingFactor: false)],
//            warmupIterations: 2,
//            scalingFactor: .one,
//            maxDuration: .seconds(60),
//            maxIterations: 5
//        )
//    ) { benchmark in
//        let messageCount = 1_000_000
//
//        for _ in benchmark.scaledIterations {
//            let channel = RCQSQueue<Int>(capacity: 4096)
//            let start = ContinuousClock.now
//
//            let producer = Thread {
//                for i in 0..<messageCount {
//                    channel.send(i)
//                }
//                channel.close()
//            }
//
//            var received = 0
//            let consumer = Thread {
//                for _ in channel {
//                    received += 1
//                }
//            }
//
//            producer.start()
//            consumer.start()
//
//            while !producer.isFinished { Thread.sleep(forTimeInterval: 0.001) }
//            while !consumer.isFinished { Thread.sleep(forTimeInterval: 0.001) }
//
//            let elapsed = ContinuousClock.now - start
//            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
//            let opsPerSec = Double(received) / seconds / 1_000_000
//            benchmark.measurement(.custom("M ops/sec", polarity: .prefersLarger, useScalingFactor: false), Int(opsPerSec * 1000))
//        }
//    }
//
//    Benchmark(
//        "RCQSQueue.MPSC.Contention",
//        configuration: .init(
//            metrics: [.custom("M ops/sec", polarity: .prefersLarger, useScalingFactor: false)],
//            warmupIterations: 2,
//            scalingFactor: .one,
//            maxDuration: .seconds(60),
//            maxIterations: 5
//        )
//    ) { benchmark in
//        let producerCount = 4
//        let messagesPerProducer = 250_000
//
//        for _ in benchmark.scaledIterations {
//            let channel = RCQSQueue<Int>(capacity: 4096)
//            let producersDone = UnsafeMutablePointer<Int>.allocate(capacity: 1)
//            producersDone.initialize(to: 0)
//            defer { producersDone.deallocate() }
//
//            let start = ContinuousClock.now
//
//            var producers: [Thread] = []
//            for p in 0..<producerCount {
//                let producer = Thread {
//                    let base = p * messagesPerProducer
//                    for i in 0..<messagesPerProducer {
//                        channel.send(base + i)
//                    }
//                    producersDone.pointee += 1
//                }
//                producers.append(producer)
//            }
//
//            var received = 0
//            let consumer = Thread {
//                while producersDone.pointee < producerCount || channel.tryRecv() != nil {
//                    if channel.tryRecv() != nil {
//                        received += 1
//                    }
//                }
//                while channel.tryRecv() != nil {
//                    received += 1
//                }
//            }
//
//            for p in producers { p.start() }
//            consumer.start()
//
//            for p in producers {
//                while !p.isFinished { Thread.sleep(forTimeInterval: 0.001) }
//            }
//            channel.close()
//            while !consumer.isFinished { Thread.sleep(forTimeInterval: 0.001) }
//
//            let elapsed = ContinuousClock.now - start
//            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
//            let totalMessages = producerCount * messagesPerProducer
//            let opsPerSec = Double(totalMessages) / seconds / 1_000_000
//            benchmark.measurement(.custom("M ops/sec", polarity: .prefersLarger, useScalingFactor: false), Int(opsPerSec * 1000))
//        }
//    }
//
//    Benchmark(
//        "RCQSQueue.RoundTrip.Latency",
//        configuration: .init(
//            metrics: [.custom("ns/roundtrip", polarity: .prefersSmaller, useScalingFactor: false)],
//            warmupIterations: 2,
//            scalingFactor: .one,
//            maxDuration: .seconds(60),
//            maxIterations: 5
//        )
//    ) { benchmark in
//        let iterations = 10_000
//
//        for _ in benchmark.scaledIterations {
//            let ping = RCQSQueue<Int>(capacity: 1024)
//            let pong = RCQSQueue<Int>(capacity: 1024)
//
//            let start = ContinuousClock.now
//
//            let sender = Thread {
//                for i in 0..<iterations {
//                    ping.send(i)
//                    _ = pong.recv()
//                }
//                ping.close()
//            }
//
//            let responder = Thread {
//                for value in ping {
//                    pong.send(value)
//                }
//                pong.close()
//            }
//
//            sender.start()
//            responder.start()
//
//            while !sender.isFinished || !responder.isFinished {
//                Thread.sleep(forTimeInterval: 0.0001)
//            }
//
//            let elapsed = ContinuousClock.now - start
//            let nanoseconds = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
//            let nsPerRoundTrip = nanoseconds / Double(iterations)
//            benchmark.measurement(.custom("ns/roundtrip", polarity: .prefersSmaller, useScalingFactor: false), Int(nsPerRoundTrip))
//        }
//    }

    // ============================================================
    // MARK: - SegmentQueue Benchmarks (segment-based relaxation)
    // ============================================================

//    Benchmark(
//        "SegmentQueue.Send.Latency",
//        configuration: .init(
//            metrics: [.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false)],
//            warmupIterations: 3,
//            scalingFactor: .one,
//            maxDuration: .seconds(30),
//            maxIterations: 20
//        )
//    ) { benchmark in
//        let iterations = 100_000
//        let channel = SegmentQueue<Int>(segmentSize: 8, capacity: 131072)
//
//        for _ in benchmark.scaledIterations {
//            let start = ContinuousClock.now
//
//            for i in 0..<iterations {
//                channel.send(i)
//            }
//
//            let elapsed = ContinuousClock.now - start
//            let nanoseconds = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
//            let nsPerOp = nanoseconds / Double(iterations)
//            benchmark.measurement(.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false), Int(nsPerOp))
//
//            while channel.tryRecv() != nil {}
//        }
//    }
//
//    Benchmark(
//        "SegmentQueue.TryRecv.Latency",
//        configuration: .init(
//            metrics: [.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false)],
//            warmupIterations: 3,
//            scalingFactor: .one,
//            maxDuration: .seconds(30),
//            maxIterations: 20
//        )
//    ) { benchmark in
//        let iterations = 100_000
//        let channel = SegmentQueue<Int>(segmentSize: 8, capacity: 131072)
//
//        for _ in benchmark.scaledIterations {
//            for i in 0..<iterations {
//                channel.send(i)
//            }
//
//            let start = ContinuousClock.now
//
//            var count = 0
//            while channel.tryRecv() != nil {
//                count += 1
//            }
//
//            let elapsed = ContinuousClock.now - start
//            let nanoseconds = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
//            let nsPerOp = nanoseconds / Double(count)
//            benchmark.measurement(.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false), Int(nsPerOp))
//        }
//    }
//
//    Benchmark(
//        "SegmentQueue.SPSC.Throughput",
//        configuration: .init(
//            metrics: [.custom("M ops/sec", polarity: .prefersLarger, useScalingFactor: false)],
//            warmupIterations: 2,
//            scalingFactor: .one,
//            maxDuration: .seconds(60),
//            maxIterations: 5
//        )
//    ) { benchmark in
//        let messageCount = 1_000_000
//
//        for _ in benchmark.scaledIterations {
//            let channel = SegmentQueue<Int>(segmentSize: 8, capacity: 4096)
//            let start = ContinuousClock.now
//
//            let producer = Thread {
//                for i in 0..<messageCount {
//                    channel.send(i)
//                }
//                channel.close()
//            }
//
//            var received = 0
//            let consumer = Thread {
//                for _ in channel {
//                    received += 1
//                }
//            }
//
//            producer.start()
//            consumer.start()
//
//            while !producer.isFinished { Thread.sleep(forTimeInterval: 0.001) }
//            while !consumer.isFinished { Thread.sleep(forTimeInterval: 0.001) }
//
//            let elapsed = ContinuousClock.now - start
//            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
//            let opsPerSec = Double(received) / seconds / 1_000_000
//            benchmark.measurement(.custom("M ops/sec", polarity: .prefersLarger, useScalingFactor: false), Int(opsPerSec * 1000))
//        }
//    }
//
//    Benchmark(
//        "SegmentQueue.MPSC.Contention",
//        configuration: .init(
//            metrics: [.custom("M ops/sec", polarity: .prefersLarger, useScalingFactor: false)],
//            warmupIterations: 2,
//            scalingFactor: .one,
//            maxDuration: .seconds(60),
//            maxIterations: 5
//        )
//    ) { benchmark in
//        let producerCount = 4
//        let messagesPerProducer = 250_000
//
//        for _ in benchmark.scaledIterations {
//            let channel = SegmentQueue<Int>(segmentSize: 8, capacity: 4096)
//            let producersDone = UnsafeMutablePointer<Int>.allocate(capacity: 1)
//            producersDone.initialize(to: 0)
//            defer { producersDone.deallocate() }
//
//            let start = ContinuousClock.now
//
//            var producers: [Thread] = []
//            for p in 0..<producerCount {
//                let producer = Thread {
//                    let base = p * messagesPerProducer
//                    for i in 0..<messagesPerProducer {
//                        channel.send(base + i)
//                    }
//                    producersDone.pointee += 1
//                }
//                producers.append(producer)
//            }
//
//            var received = 0
//            let consumer = Thread {
//                while producersDone.pointee < producerCount || channel.tryRecv() != nil {
//                    if channel.tryRecv() != nil {
//                        received += 1
//                    }
//                }
//                while channel.tryRecv() != nil {
//                    received += 1
//                }
//            }
//
//            for p in producers { p.start() }
//            consumer.start()
//
//            for p in producers {
//                while !p.isFinished { Thread.sleep(forTimeInterval: 0.001) }
//            }
//            channel.close()
//            while !consumer.isFinished { Thread.sleep(forTimeInterval: 0.001) }
//
//            let elapsed = ContinuousClock.now - start
//            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
//            let totalMessages = producerCount * messagesPerProducer
//            let opsPerSec = Double(totalMessages) / seconds / 1_000_000
//            benchmark.measurement(.custom("M ops/sec", polarity: .prefersLarger, useScalingFactor: false), Int(opsPerSec * 1000))
//        }
//    }
//
//    Benchmark(
//        "SegmentQueue.RoundTrip.Latency",
//        configuration: .init(
//            metrics: [.custom("ns/roundtrip", polarity: .prefersSmaller, useScalingFactor: false)],
//            warmupIterations: 2,
//            scalingFactor: .one,
//            maxDuration: .seconds(60),
//            maxIterations: 5
//        )
//    ) { benchmark in
//        let iterations = 10_000
//
//        for _ in benchmark.scaledIterations {
//            let ping = SegmentQueue<Int>(segmentSize: 8, capacity: 1024)
//            let pong = SegmentQueue<Int>(segmentSize: 8, capacity: 1024)
//
//            let start = ContinuousClock.now
//
//            let sender = Thread {
//                for i in 0..<iterations {
//                    ping.send(i)
//                    _ = pong.recv()
//                }
//                ping.close()
//            }
//
//            let responder = Thread {
//                for value in ping {
//                    pong.send(value)
//                }
//                pong.close()
//            }
//
//            sender.start()
//            responder.start()
//
//            while !sender.isFinished || !responder.isFinished {
//                Thread.sleep(forTimeInterval: 0.0001)
//            }
//
//            let elapsed = ContinuousClock.now - start
//            let nanoseconds = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
//            let nsPerRoundTrip = nanoseconds / Double(iterations)
//            benchmark.measurement(.custom("ns/roundtrip", polarity: .prefersSmaller, useScalingFactor: false), Int(nsPerRoundTrip))
//        }
//    }

    // ============================================================
    // MARK: - RCQChannel Benchmarks (real concurrent queue)
    // ============================================================

    Benchmark(
        "RCQChannel.Send.Latency",
        configuration: .init(
            metrics: [.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false)],
            warmupIterations: 3,
            scalingFactor: .one,
            maxDuration: .seconds(30),
            maxIterations: 20
        )
    ) { benchmark in
        let iterations = 100_000
        let channel = RCQChannel<Int>(size: 131072)

        for _ in benchmark.scaledIterations {
            let start = ContinuousClock.now

            for i in 0..<iterations {
                channel.send(i)
            }

            let elapsed = ContinuousClock.now - start
            let nanoseconds = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
            let nsPerOp = nanoseconds / Double(iterations)
            benchmark.measurement(.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false), Int(nsPerOp))

            // Close before draining - receive() is blocking
            channel.close()
            while channel.receive() != nil {}
        }
    }

    Benchmark(
        "RCQChannel.Receive.Latency",
        configuration: .init(
            metrics: [.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false)],
            warmupIterations: 3,
            scalingFactor: .one,
            maxDuration: .seconds(30),
            maxIterations: 20
        )
    ) { benchmark in
        let iterations = 100_000
        let channel = RCQChannel<Int>(size: 131072)

        for _ in benchmark.scaledIterations {
            for i in 0..<iterations {
                channel.send(i)
            }
            channel.close()

            let start = ContinuousClock.now

            var count = 0
            while channel.receive() != nil {
                count += 1
            }

            let elapsed = ContinuousClock.now - start
            let nanoseconds = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
            let nsPerOp = nanoseconds / Double(count)
            benchmark.measurement(.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false), Int(nsPerOp))

            while channel.receive() != nil {}
        }
    }

    Benchmark(
        "RCQChannel.SPSC.Throughput",
        configuration: .init(
            metrics: [.custom("M ops/sec", polarity: .prefersLarger, useScalingFactor: false)],
            warmupIterations: 2,
            scalingFactor: .one,
            maxDuration: .seconds(60),
            maxIterations: 5
        )
    ) { benchmark in
        let messageCount = 1_000_000

        for _ in benchmark.scaledIterations {
            let channel = RCQChannel<Int>(size: 4096)
            let start = ContinuousClock.now

            let producer = Thread {
                for i in 0..<messageCount {
                    channel.send(i)
                }
                channel.close()
            }

            var received = 0
            let consumer = Thread {
                while true {
                    if let _ = channel.receive() {
                        received += 1
                    } else {
                        break
                    }
                }
            }

            producer.start()
            consumer.start()

            while !producer.isFinished { Thread.sleep(forTimeInterval: 0.001) }
            while !consumer.isFinished { Thread.sleep(forTimeInterval: 0.001) }

            let elapsed = ContinuousClock.now - start
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let opsPerSec = Double(received) / seconds / 1_000_000
            benchmark.measurement(.custom("M ops/sec", polarity: .prefersLarger, useScalingFactor: false), Int(opsPerSec * 1000))

            // Close before draining - receive() is blocking
            channel.close()
            while channel.receive() != nil {}
        }
    }

    Benchmark(
        "RCQChannel.MPSC.Contention",
        configuration: .init(
            metrics: [.custom("M ops/sec", polarity: .prefersLarger, useScalingFactor: false)],
            warmupIterations: 2,
            scalingFactor: .one,
            maxDuration: .seconds(60),
            maxIterations: 5
        )
    ) { benchmark in
        let producerCount = 4
        let messagesPerProducer = 250_000

        for _ in benchmark.scaledIterations {
            let channel = RCQChannel<Int>(size: 4096)
            let start = ContinuousClock.now


            let received = await withTaskGroup { group in
                let producersDone = SyncBox<Int>(0)

                group.addTask {
                    var received = 0
                    while channel.receive() != nil {
                        received += 1
                    }

                    return received
                }

                for p in 0..<producerCount {
                    group.addTask {
                        let base = p * messagesPerProducer
                        for i in 0..<messagesPerProducer {
                            channel.send(base + i)
                        }
                        producersDone.update { $0 += 1 }

                        return 0
                    }
                }

                var receivedCount = 0
                for await result in group {
                    receivedCount += result
                    if producersDone.value == producerCount {
                        channel.close()
                    }
                }

                return receivedCount
            }


            let elapsed = ContinuousClock.now - start
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let totalMessages = producerCount * messagesPerProducer
            let opsPerSec = Double(totalMessages) / seconds / 1_000_000
            benchmark.measurement(.custom("M ops/sec", polarity: .prefersLarger, useScalingFactor: false), Int(opsPerSec * 1000))
        }
    }

    Benchmark(
        "RCQChannel.RoundTrip.Latency",
        configuration: .init(
            metrics: [.custom("ns/roundtrip", polarity: .prefersSmaller, useScalingFactor: false)],
            warmupIterations: 2,
            scalingFactor: .one,
            maxDuration: .seconds(60),
            maxIterations: 5
        )
    ) { benchmark in
        let iterations = 10_000
        for _ in benchmark.scaledIterations {
            let ping = RCQChannel<Int>(size: 1024)
            let pong = RCQChannel<Int>(size: 1024)

            let start = ContinuousClock.now

            try await withTaskGroup { group in
                group.addTask {
                    while true {
                        if let value = ping.receive() {
                            pong.send(value)
                        } else {
                            break
                        }
                    }
                    print("pong close")
                    pong.close()
                }

                group.addTask {
                    for i in 0..<iterations {
                        ping.send(i)
                        // Spin until we get a response
                        if let _ = pong.receive() {
                        } else {
                            print("pong break")
                            break
                        }
                    }
                    ping.close()
                }

                await group.waitForAll()
            }

            let elapsed = ContinuousClock.now - start
            let nanoseconds = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
            let nsPerRoundTrip = nanoseconds / Double(iterations)
            benchmark.measurement(.custom("ns/roundtrip", polarity: .prefersSmaller, useScalingFactor: false), Int(nsPerRoundTrip))
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
