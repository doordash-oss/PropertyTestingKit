//
//  RelaxedBoundedChannelTests.swift
//  PropertyTestingKit
//
//  Tests for RelaxedBoundedChannel to verify correct behavior.
//

//import Testing
//import Foundation
//@testable import ConcurrentQueues
//
//@Suite("RelaxedBoundedChannel Tests")
//struct RelaxedBoundedChannelTests {
//
//    // MARK: - Basic Functionality
//
//    @Test("Send and receive single element")
//    func sendReceiveSingle() {
//        let channel = RelaxedBoundedChannel<Int>(capacity: 16)
//
//        channel.send(42)
//        let received = channel.tryRecv()
//
//        #expect(received == 42)
//    }
//
//    @Test("Send and receive multiple elements in order")
//    func sendReceiveMultipleInOrder() {
//        let channel = RelaxedBoundedChannel<Int>(capacity: 16)
//
//        for i in 0..<10 {
//            channel.send(i)
//        }
//
//        for i in 0..<10 {
//            let received = channel.tryRecv()
//            #expect(received == i, "Expected \(i), got \(String(describing: received))")
//        }
//
//        #expect(channel.tryRecv() == nil, "Channel should be empty")
//    }
//
//    @Test("tryRecv returns nil when empty")
//    func tryRecvEmpty() {
//        let channel = RelaxedBoundedChannel<Int>(capacity: 16)
//
//        #expect(channel.tryRecv() == nil)
//    }
//
//    @Test("Close channel stops recv")
//    func closeChannel() {
//        let channel = RelaxedBoundedChannel<Int>(capacity: 16)
//
//        channel.send(1)
//        channel.close()
//
//        #expect(channel.isClosed)
//        #expect(channel.tryRecv() == 1)
//        #expect(channel.tryRecv() == nil)
//    }
//
//    // MARK: - SPSC (Single Producer Single Consumer)
//
//    @Test("SPSC throughput - many messages")
//    func spscThroughput() {
//        let messageCount = 10_000
//        let channel = RelaxedBoundedChannel<Int>(capacity: messageCount.nextPowerOf2())
//
//        // Send all messages
//        for i in 0..<messageCount {
//            channel.send(i)
//        }
//
//        // Receive all messages
//        var received = 0
//        while channel.tryRecv() != nil {
//            received += 1
//        }
//
//        #expect(received == messageCount)
//    }
//
//    @Test("SPSC with interleaved send/recv")
//    func spscInterleaved() {
//        let channel = RelaxedBoundedChannel<Int>(capacity: 16)
//
//        for i in 0..<100 {
//            channel.send(i)
//            let received = channel.tryRecv()
//            #expect(received == i)
//        }
//    }
//
//    // MARK: - Sequence Iteration
//
//    @Test("Sequence iteration receives all elements")
//    func sequenceIteration() {
//        let channel = RelaxedBoundedChannel<Int>(capacity: 16)
//
//        for i in 0..<5 {
//            channel.send(i)
//        }
//        channel.close()
//
//        var received: [Int] = []
//        for value in channel {
//            received.append(value)
//        }
//
//        #expect(received == [0, 1, 2, 3, 4])
//    }
//
//    // MARK: - Out-of-Order Consumption Simulation
//
//    @Test("Handles slots being ready out of order")
//    func outOfOrderSlots() {
//        // This tests the core relaxed ordering feature
//        // We simulate a scenario where later slots are ready before earlier ones
//
//        let channel = RelaxedBoundedChannel<Int>(capacity: 16, scanLimit: 8)
//
//        // Send multiple messages
//        for i in 0..<5 {
//            channel.send(i)
//        }
//
//        // In SPSC, they should all be ready in order, but let's verify
//        // the channel can handle receiving them
//        var received: [Int] = []
//        while let value = channel.tryRecv() {
//            received.append(value)
//        }
//
//        #expect(received.count == 5)
//        #expect(Set(received) == Set([0, 1, 2, 3, 4]), "Should receive all values")
//    }
//
//    // MARK: - Edge Cases
//
//    @Test("Capacity 1 channel works")
//    func capacityOne() {
//        let channel = RelaxedBoundedChannel<Int>(capacity: 1)
//
//        channel.send(1)
//        #expect(channel.tryRecv() == 1)
//
//        channel.send(2)
//        #expect(channel.tryRecv() == 2)
//
//        channel.send(3)
//        #expect(channel.tryRecv() == 3)
//    }
//
//    @Test("Large capacity channel works")
//    func largeCapacity() {
//        let channel = RelaxedBoundedChannel<Int>(capacity: 65536)
//
//        for i in 0..<1000 {
//            channel.send(i)
//        }
//
//        var count = 0
//        while channel.tryRecv() != nil {
//            count += 1
//        }
//
//        #expect(count == 1000)
//    }
//
//    @Test("Wrap around works correctly")
//    func wrapAround() {
//        let channel = RelaxedBoundedChannel<Int>(capacity: 4)
//
//        // Fill and drain multiple times to test wrap-around
//        for round in 0..<10 {
//            for i in 0..<4 {
//                channel.send(round * 4 + i)
//            }
//
//            for i in 0..<4 {
//                let expected = round * 4 + i
//                let received = channel.tryRecv()
//                #expect(received == expected, "Round \(round), expected \(expected), got \(String(describing: received))")
//            }
//        }
//    }
//
//    @Test("recv returns element when available")
//    func recvWithData() {
//        let channel = RelaxedBoundedChannel<Int>(capacity: 16)
//        channel.send(42)
//
//        let received = channel.recv()
//        #expect(received == 42)
//    }
//
//    @Test("recv returns nil when closed and empty")
//    func recvClosedEmpty() {
//        let channel = RelaxedBoundedChannel<Int>(capacity: 16)
//        channel.close()
//
//        let received = channel.recv()
//        #expect(received == nil)
//    }
//
//    // MARK: - Stress Tests with Atomics
//
//    @Test("Stress test with rapid send/recv cycles")
//    func stressTest() {
//        let channel = RelaxedBoundedChannel<Int>(capacity: 64)
//
//        // Rapid send/recv cycles
//        for cycle in 0..<100 {
//            // Fill partially
//            for i in 0..<32 {
//                channel.send(cycle * 32 + i)
//            }
//
//            // Drain
//            var count = 0
//            while channel.tryRecv() != nil {
//                count += 1
//            }
//
//            #expect(count == 32, "Cycle \(cycle): expected 32, got \(count)")
//        }
//    }
//
//    @Test("Multiple partial fill/drain cycles")
//    func partialFillDrain() {
//        let channel = RelaxedBoundedChannel<Int>(capacity: 8)
//
//        for _ in 0..<50 {
//            // Send 3
//            channel.send(1)
//            channel.send(2)
//            channel.send(3)
//
//            // Recv 2
//            _ = channel.tryRecv()
//            _ = channel.tryRecv()
//
//            // Send 2 more
//            channel.send(4)
//            channel.send(5)
//
//            // Drain all
//            var count = 0
//            while channel.tryRecv() != nil {
//                count += 1
//            }
//
//            #expect(count == 3, "Expected 3 remaining, got \(count)")
//        }
//    }
//}
