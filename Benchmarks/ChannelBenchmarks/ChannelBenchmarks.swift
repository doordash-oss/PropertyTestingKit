//
//  ChannelBenchmarks.swift
//  PropertyTestingKit
//
//  Performance benchmarks for Channel operations.
//

import Benchmark
import Foundation
import PropertyTestingKit

let benchmarks: @Sendable () -> Void = {

    // ============================================================
    // MARK: - Async Channel Benchmarks
    // ============================================================

    // MARK: - Send Latency (no contention, large buffer)

    Benchmark(
        "AsyncChannel.Send.Latency",
        configuration: .init(
            metrics: [.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false)],
            warmupIterations: 3,
            scalingFactor: .one,
            maxDuration: .seconds(30),
            maxIterations: 20
        )
    ) { benchmark in
        let iterations = 100_000
        let channel = Channel<Int>(capacity: 131072)  // Large buffer

        for _ in benchmark.scaledIterations {
            let start = ContinuousClock.now

            for i in 0..<iterations {
                channel.send(i)
            }

            let elapsed = ContinuousClock.now - start
            let nanoseconds = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
            let nsPerOp = nanoseconds / Double(iterations)
            benchmark.measurement(.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false), Int(nsPerOp))

            // Drain
            while channel.tryRecv() != nil {}
        }
    }

    // MARK: - TryRecv Latency (data available)

    Benchmark(
        "AsyncChannel.TryRecv.Latency",
        configuration: .init(
            metrics: [.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false)],
            warmupIterations: 3,
            scalingFactor: .one,
            maxDuration: .seconds(30),
            maxIterations: 20
        )
    ) { benchmark in
        let iterations = 100_000
        let channel = Channel<Int>(capacity: 131072)

        for _ in benchmark.scaledIterations {
            // Fill
            for i in 0..<iterations {
                channel.send(i)
            }

            let start = ContinuousClock.now

            var count = 0
            while channel.tryRecv() != nil {
                count += 1
            }

            let elapsed = ContinuousClock.now - start
            let nanoseconds = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
            let nsPerOp = nanoseconds / Double(count)
            benchmark.measurement(.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false), Int(nsPerOp))
        }
    }

    // MARK: - SPSC Throughput

    Benchmark(
        "AsyncChannel.SPSC.Throughput",
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
            let channel = Channel<Int>(capacity: 4096)
            let start = ContinuousClock.now

            await withTaskGroup(of: Void.self) { group in
                // Producer
                group.addTask {
                    for i in 0..<messageCount {
                        channel.send(i)
                    }
                    channel.close()
                }

                // Consumer
                group.addTask {
                    var count = 0
                    for await _ in channel {
                        count += 1
                    }
                    blackHole(count)
                }
            }

            let elapsed = ContinuousClock.now - start
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let opsPerSec = Double(messageCount) / seconds / 1_000_000
            benchmark.measurement(.custom("M ops/sec", polarity: .prefersLarger, useScalingFactor: false), Int(opsPerSec * 1000))
        }
    }

    // MARK: - Round Trip Latency

    Benchmark(
        "AsyncChannel.RoundTrip.Latency",
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
            let ping = Channel<Int>(capacity: 1)
            let pong = Channel<Int>(capacity: 1)

            let start = ContinuousClock.now

            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for i in 0..<iterations {
                        ping.send(i)
                        _ = await pong.recv()
                    }
                    ping.close()
                }

                group.addTask {
                    for await value in ping {
                        pong.send(value)
                    }
                    pong.close()
                }
            }

            let elapsed = ContinuousClock.now - start
            let nanoseconds = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
            let nsPerRoundTrip = nanoseconds / Double(iterations)
            benchmark.measurement(.custom("ns/roundtrip", polarity: .prefersSmaller, useScalingFactor: false), Int(nsPerRoundTrip))
        }
    }

    // ============================================================
    // MARK: - Sync Channel Benchmarks (semaphore-based blocking)
    // ============================================================

    Benchmark(
        "SyncChannel.Send.Latency",
        configuration: .init(
            metrics: [.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false)],
            warmupIterations: 3,
            scalingFactor: .one,
            maxDuration: .seconds(30),
            maxIterations: 20
        )
    ) { benchmark in
        let iterations = 100_000
        let channel = SyncChannel<Int>(capacity: 131072)

        for _ in benchmark.scaledIterations {
            let start = ContinuousClock.now

            for i in 0..<iterations {
                channel.send(i)
            }

            let elapsed = ContinuousClock.now - start
            let nanoseconds = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
            let nsPerOp = nanoseconds / Double(iterations)
            benchmark.measurement(.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false), Int(nsPerOp))

            while channel.tryRecv() != nil {}
        }
    }

    Benchmark(
        "SyncChannel.TryRecv.Latency",
        configuration: .init(
            metrics: [.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false)],
            warmupIterations: 3,
            scalingFactor: .one,
            maxDuration: .seconds(30),
            maxIterations: 20
        )
    ) { benchmark in
        let iterations = 100_000
        let channel = SyncChannel<Int>(capacity: 131072)

        for _ in benchmark.scaledIterations {
            for i in 0..<iterations {
                channel.send(i)
            }

            let start = ContinuousClock.now

            var count = 0
            while channel.tryRecv() != nil {
                count += 1
            }

            let elapsed = ContinuousClock.now - start
            let nanoseconds = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
            let nsPerOp = nanoseconds / Double(count)
            benchmark.measurement(.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false), Int(nsPerOp))
        }
    }

    Benchmark(
        "SyncChannel.SPSC.Throughput",
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
            let channel = SyncChannel<Int>(capacity: 4096)
            let start = ContinuousClock.now

            // Use actual threads instead of async tasks
            let producer = Thread {
                for i in 0..<messageCount {
                    channel.send(i)
                }
                channel.close()
            }

            var received = 0
            let consumer = Thread {
                for _ in channel {
                    received += 1
                }
            }

            producer.start()
            consumer.start()

            // Wait for threads to complete
            while !producer.isFinished || !consumer.isFinished {
                Thread.sleep(forTimeInterval: 0.001)
            }

            let elapsed = ContinuousClock.now - start
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let opsPerSec = Double(messageCount) / seconds / 1_000_000
            benchmark.measurement(.custom("M ops/sec", polarity: .prefersLarger, useScalingFactor: false), Int(opsPerSec * 1000))
        }
    }

    Benchmark(
        "SyncChannel.RoundTrip.Latency",
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
            let ping = SyncChannel<Int>(capacity: 1)
            let pong = SyncChannel<Int>(capacity: 1)

            let start = ContinuousClock.now

            let sender = Thread {
                for i in 0..<iterations {
                    ping.send(i)
                    _ = pong.recv()
                }
                ping.close()
            }

            let responder = Thread {
                for value in ping {
                    pong.send(value)
                }
                pong.close()
            }

            sender.start()
            responder.start()

            while !sender.isFinished || !responder.isFinished {
                Thread.sleep(forTimeInterval: 0.0001)
            }

            let elapsed = ContinuousClock.now - start
            let nanoseconds = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
            let nsPerRoundTrip = nanoseconds / Double(iterations)
            benchmark.measurement(.custom("ns/roundtrip", polarity: .prefersSmaller, useScalingFactor: false), Int(nsPerRoundTrip))
        }
    }

    // ============================================================
    // MARK: - Spin Channel Benchmarks (busy-wait strategy)
    // ============================================================

    Benchmark(
        "SpinChannel.Send.Latency",
        configuration: .init(
            metrics: [.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false)],
            warmupIterations: 3,
            scalingFactor: .one,
            maxDuration: .seconds(30),
            maxIterations: 20
        )
    ) { benchmark in
        let iterations = 100_000
        let channel = SpinChannel<Int>(capacity: 131072)

        for _ in benchmark.scaledIterations {
            let start = ContinuousClock.now

            for i in 0..<iterations {
                channel.send(i)
            }

            let elapsed = ContinuousClock.now - start
            let nanoseconds = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
            let nsPerOp = nanoseconds / Double(iterations)
            benchmark.measurement(.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false), Int(nsPerOp))

            while channel.tryRecv() != nil {}
        }
    }

    Benchmark(
        "SpinChannel.TryRecv.Latency",
        configuration: .init(
            metrics: [.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false)],
            warmupIterations: 3,
            scalingFactor: .one,
            maxDuration: .seconds(30),
            maxIterations: 20
        )
    ) { benchmark in
        let iterations = 100_000
        let channel = SpinChannel<Int>(capacity: 131072)

        for _ in benchmark.scaledIterations {
            for i in 0..<iterations {
                channel.send(i)
            }

            let start = ContinuousClock.now

            var count = 0
            while channel.tryRecv() != nil {
                count += 1
            }

            let elapsed = ContinuousClock.now - start
            let nanoseconds = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
            let nsPerOp = nanoseconds / Double(count)
            benchmark.measurement(.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false), Int(nsPerOp))
        }
    }

    Benchmark(
        "SpinChannel.SPSC.Throughput",
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
            let channel = SpinChannel<Int>(capacity: 4096)
            let start = ContinuousClock.now

            let producer = Thread {
                for i in 0..<messageCount {
                    channel.send(i)
                }
                channel.close()
            }

            var received = 0
            let consumer = Thread {
                for _ in channel {
                    received += 1
                }
            }

            producer.start()
            consumer.start()

            while !producer.isFinished || !consumer.isFinished {
                Thread.sleep(forTimeInterval: 0.001)
            }

            let elapsed = ContinuousClock.now - start
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let opsPerSec = Double(messageCount) / seconds / 1_000_000
            benchmark.measurement(.custom("M ops/sec", polarity: .prefersLarger, useScalingFactor: false), Int(opsPerSec * 1000))
        }
    }

    Benchmark(
        "SpinChannel.RoundTrip.Latency",
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
            let ping = SpinChannel<Int>(capacity: 1)
            let pong = SpinChannel<Int>(capacity: 1)

            let start = ContinuousClock.now

            let sender = Thread {
                for i in 0..<iterations {
                    ping.send(i)
                    _ = pong.recv()
                }
                ping.close()
            }

            let responder = Thread {
                for value in ping {
                    pong.send(value)
                }
                pong.close()
            }

            sender.start()
            responder.start()

            while !sender.isFinished || !responder.isFinished {
                Thread.sleep(forTimeInterval: 0.0001)
            }

            let elapsed = ContinuousClock.now - start
            let nanoseconds = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
            let nsPerRoundTrip = nanoseconds / Double(iterations)
            benchmark.measurement(.custom("ns/roundtrip", polarity: .prefersSmaller, useScalingFactor: false), Int(nsPerRoundTrip))
        }
    }

    // ============================================================
    // MARK: - Vyukov Channel Benchmarks (wait-free XCHG producers)
    // ============================================================

    Benchmark(
        "VyukovChannel.Send.Latency",
        configuration: .init(
            metrics: [.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false)],
            warmupIterations: 3,
            scalingFactor: .one,
            maxDuration: .seconds(30),
            maxIterations: 20
        )
    ) { benchmark in
        let iterations = 100_000

        for _ in benchmark.scaledIterations {
            let channel = VyukovChannel<Int>()

            let start = ContinuousClock.now

            for i in 0..<iterations {
                channel.send(i)
            }

            let elapsed = ContinuousClock.now - start
            let nanoseconds = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
            let nsPerOp = nanoseconds / Double(iterations)
            benchmark.measurement(.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false), Int(nsPerOp))

            // Drain
            while channel.tryRecv() != nil {}
        }
    }

    Benchmark(
        "VyukovChannel.TryRecv.Latency",
        configuration: .init(
            metrics: [.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false)],
            warmupIterations: 3,
            scalingFactor: .one,
            maxDuration: .seconds(30),
            maxIterations: 20
        )
    ) { benchmark in
        let iterations = 100_000

        for _ in benchmark.scaledIterations {
            let channel = VyukovChannel<Int>()

            // Fill
            for i in 0..<iterations {
                channel.send(i)
            }

            let start = ContinuousClock.now

            var count = 0
            while channel.tryRecv() != nil {
                count += 1
            }

            let elapsed = ContinuousClock.now - start
            let nanoseconds = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
            let nsPerOp = nanoseconds / Double(count)
            benchmark.measurement(.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false), Int(nsPerOp))
        }
    }

    Benchmark(
        "VyukovChannel.SPSC.Throughput",
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
            let channel = VyukovChannel<Int>()
            let start = ContinuousClock.now

            let producer = Thread {
                for i in 0..<messageCount {
                    channel.send(i)
                }
                channel.close()
            }

            var received = 0
            let consumer = Thread {
                for _ in channel {
                    received += 1
                }
            }

            producer.start()
            consumer.start()

            while !producer.isFinished || !consumer.isFinished {
                Thread.sleep(forTimeInterval: 0.001)
            }

            let elapsed = ContinuousClock.now - start
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let opsPerSec = Double(messageCount) / seconds / 1_000_000
            benchmark.measurement(.custom("M ops/sec", polarity: .prefersLarger, useScalingFactor: false), Int(opsPerSec * 1000))
        }
    }

    Benchmark(
        "VyukovChannel.RoundTrip.Latency",
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
            let ping = VyukovChannel<Int>()
            let pong = VyukovChannel<Int>()

            let start = ContinuousClock.now

            let sender = Thread {
                for i in 0..<iterations {
                    ping.send(i)
                    _ = pong.recv()
                }
                ping.close()
            }

            let responder = Thread {
                for value in ping {
                    pong.send(value)
                }
                pong.close()
            }

            sender.start()
            responder.start()

            while !sender.isFinished || !responder.isFinished {
                Thread.sleep(forTimeInterval: 0.0001)
            }

            let elapsed = ContinuousClock.now - start
            let nanoseconds = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
            let nsPerRoundTrip = nanoseconds / Double(iterations)
            benchmark.measurement(.custom("ns/roundtrip", polarity: .prefersSmaller, useScalingFactor: false), Int(nsPerRoundTrip))
        }
    }

    // ============================================================
    // MARK: - Vyukov Bounded Channel Benchmarks (sequence number technique)
    // ============================================================

    Benchmark(
        "VyukovBoundedChannel.Send.Latency",
        configuration: .init(
            metrics: [.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false)],
            warmupIterations: 3,
            scalingFactor: .one,
            maxDuration: .seconds(30),
            maxIterations: 20
        )
    ) { benchmark in
        let iterations = 100_000
        let channel = VyukovBoundedChannel<Int>(capacity: 131072)

        for _ in benchmark.scaledIterations {
            let start = ContinuousClock.now

            for i in 0..<iterations {
                channel.send(i)
            }

            let elapsed = ContinuousClock.now - start
            let nanoseconds = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
            let nsPerOp = nanoseconds / Double(iterations)
            benchmark.measurement(.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false), Int(nsPerOp))

            while channel.tryRecv() != nil {}
        }
    }

    Benchmark(
        "VyukovBoundedChannel.TryRecv.Latency",
        configuration: .init(
            metrics: [.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false)],
            warmupIterations: 3,
            scalingFactor: .one,
            maxDuration: .seconds(30),
            maxIterations: 20
        )
    ) { benchmark in
        let iterations = 100_000
        let channel = VyukovBoundedChannel<Int>(capacity: 131072)

        for _ in benchmark.scaledIterations {
            for i in 0..<iterations {
                channel.send(i)
            }

            let start = ContinuousClock.now

            var count = 0
            while channel.tryRecv() != nil {
                count += 1
            }

            let elapsed = ContinuousClock.now - start
            let nanoseconds = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
            let nsPerOp = nanoseconds / Double(count)
            benchmark.measurement(.custom("ns/op", polarity: .prefersSmaller, useScalingFactor: false), Int(nsPerOp))
        }
    }

    Benchmark(
        "VyukovBoundedChannel.SPSC.Throughput",
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
            let channel = VyukovBoundedChannel<Int>(capacity: 4096)
            let start = ContinuousClock.now

            let producer = Thread {
                for i in 0..<messageCount {
                    channel.send(i)
                }
                channel.close()
            }

            var received = 0
            let consumer = Thread {
                for _ in channel {
                    received += 1
                }
            }

            producer.start()
            consumer.start()

            while !producer.isFinished || !consumer.isFinished {
                Thread.sleep(forTimeInterval: 0.001)
            }

            let elapsed = ContinuousClock.now - start
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let opsPerSec = Double(messageCount) / seconds / 1_000_000
            benchmark.measurement(.custom("M ops/sec", polarity: .prefersLarger, useScalingFactor: false), Int(opsPerSec * 1000))
        }
    }

    Benchmark(
        "VyukovBoundedChannel.RoundTrip.Latency",
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
            let ping = VyukovBoundedChannel<Int>(capacity: 1)
            let pong = VyukovBoundedChannel<Int>(capacity: 1)

            let start = ContinuousClock.now

            let sender = Thread {
                for i in 0..<iterations {
                    ping.send(i)
                    _ = pong.recv()
                }
                ping.close()
            }

            let responder = Thread {
                for value in ping {
                    pong.send(value)
                }
                pong.close()
            }

            sender.start()
            responder.start()

            while !sender.isFinished || !responder.isFinished {
                Thread.sleep(forTimeInterval: 0.0001)
            }

            let elapsed = ContinuousClock.now - start
            let nanoseconds = Double(elapsed.components.seconds) * 1e9 + Double(elapsed.components.attoseconds) / 1e9
            let nsPerRoundTrip = nanoseconds / Double(iterations)
            benchmark.measurement(.custom("ns/roundtrip", polarity: .prefersSmaller, useScalingFactor: false), Int(nsPerRoundTrip))
        }
    }
}
