////
////  ChannelTests.swift
////  PropertyTestingKitTests
////
////  Tests for the high-performance SPSC Channel.
////
//
//import Testing
//import Foundation
//import Atomics
//@testable import ConcurrentQueues
//
//@Suite("Channel")
//struct ChannelTests {
//
//    @Test("Send and receive single message")
//    func testSendRecvSingle() async {
//        let channel = Channel<Int>()
//
//        channel.send(42)
//        let received = await channel.recv()
//
//        #expect(received == 42)
//    }
//
//    @Test("Send multiple messages and receive in order")
//    func testFIFOOrder() async {
//        let channel = Channel<Int>()
//
//        for i in 0..<10 {
//            channel.send(i)
//        }
//
//        for i in 0..<10 {
//            let received = await channel.recv()
//            #expect(received == i)
//        }
//    }
//
//    @Test("Recv blocks until send")
//    func testRecvBlocksUntilSend() async {
//        let channel = Channel<Int>()
//
//        let task = Task {
//            await channel.recv()
//        }
//
//        // Give recv time to start waiting
//        try? await Task.sleep(for: .milliseconds(10))
//
//        channel.send(123)
//        let result = await task.value
//
//        #expect(result == 123)
//    }
//
//    @Test("Close unblocks waiting recv with nil")
//    func testCloseUnblocksRecv() async {
//        let channel = Channel<Int>()
//
//        let task = Task {
//            await channel.recv()
//        }
//
//        // Give recv time to start waiting
//        try? await Task.sleep(for: .milliseconds(10))
//
//        channel.close()
//        let result = await task.value
//
//        #expect(result == nil)
//    }
//
//    @Test("Recv returns nil after close and drain")
//    func testRecvNilAfterCloseDrain() async {
//        let channel = Channel<Int>()
//
//        channel.send(1)
//        channel.send(2)
//        channel.close()
//
//        let first = await channel.recv()
//        let second = await channel.recv()
//        let third = await channel.recv()
//
//        #expect(first == 1)
//        #expect(second == 2)
//        #expect(third == nil)
//    }
//
//    @Test("AsyncSequence iteration")
//    func testAsyncSequence() async {
//        let channel = Channel<Int>()
//
//        for i in 0..<5 {
//            channel.send(i)
//        }
//        channel.close()
//
//        var received: [Int] = []
//        for await value in channel {
//            received.append(value)
//        }
//
//        #expect(received == [0, 1, 2, 3, 4])
//    }
//
//    @Test("Backpressure when full")
//    func testBackpressureWhenFull() async {
//        let channel = Channel<Int>(capacity: 4)  // Will be rounded to 4
//
//        // Fill buffer
//        for i in 0..<4 {
//            channel.send(i)
//        }
//
//        // Start a producer that will block due to backpressure
//        let producerStarted = ManagedAtomic<Bool>(false)
//        let producer = Task {
//            producerStarted.store(true, ordering: .releasing)
//            channel.send(100)  // This should block until we consume
//        }
//
//        // Wait for producer to start
//        while !producerStarted.load(ordering: .acquiring) {
//            try? await Task.sleep(for: .milliseconds(1))
//        }
//
//        // Give send time to block
//        try? await Task.sleep(for: .milliseconds(10))
//
//        // Consume one to unblock the producer
//        let first = await channel.recv()
//        #expect(first == 0)
//
//        // Wait for producer to complete
//        await producer.value
//
//        // Receive remaining messages in order
//        let second = await channel.recv()
//        let third = await channel.recv()
//        let fourth = await channel.recv()
//        let fifth = await channel.recv()
//
//        #expect(second == 1)
//        #expect(third == 2)
//        #expect(fourth == 3)
//        #expect(fifth == 100)  // The blocked message was delivered
//    }
//
//    @Test("Capacity rounds to power of 2")
//    func testCapacityRounding() async {
//        let channel = Channel<Int>(capacity: 5)
//
//        // Should round to 8, so we can send 8 without blocking
//        for i in 0..<8 {
//            channel.send(i)
//        }
//
//        // Verify all 8 messages are in the queue
//        for i in 0..<8 {
//            let received = await channel.recv()
//            #expect(received == i)
//        }
//    }
//
//    @Test("High throughput producer-consumer")
//    func testHighThroughput() async {
//        let channel = Channel<Int>(capacity: 1024)
//        let messageCount = 10_000
//
//        // Producer task
//        let producer = Task {
//            for i in 0..<messageCount {
//                channel.send(i)
//            }
//            channel.close()
//        }
//
//        // Consumer
//        var received = 0
//        for await _ in channel {
//            received += 1
//        }
//
//        await producer.value
//
//        // With backpressure, all messages should be delivered
//        #expect(received == messageCount)
//    }
//
//    @Test("isClosed reflects state")
//    func testIsClosedState() async {
//        let channel = Channel<Int>()
//
//        #expect(channel.isClosed == false)
//
//        channel.close()
//
//        #expect(channel.isClosed == true)
//    }
//}
