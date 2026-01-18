//
//  ChannelTests.swift
//  PropertyTestingKitTests
//
//  Tests for the high-performance SPSC Channel.
//

import Testing
import Foundation
@testable import PropertyTestingKit

@Suite("Channel")
struct ChannelTests {

    @Test("Send and receive single message")
    func testSendRecvSingle() async {
        let channel = Channel<Int>()

        channel.send(42)
        let received = await channel.recv()

        #expect(received == 42)
    }

    @Test("Send multiple messages and receive in order")
    func testFIFOOrder() async {
        let channel = Channel<Int>()

        for i in 0..<10 {
            channel.send(i)
        }

        for i in 0..<10 {
            let received = await channel.recv()
            #expect(received == i)
        }
    }

    @Test("Recv blocks until send")
    func testRecvBlocksUntilSend() async {
        let channel = Channel<Int>()

        let task = Task {
            await channel.recv()
        }

        // Give recv time to start waiting
        try? await Task.sleep(for: .milliseconds(10))

        channel.send(123)
        let result = await task.value

        #expect(result == 123)
    }

    @Test("Close unblocks waiting recv with nil")
    func testCloseUnblocksRecv() async {
        let channel = Channel<Int>()

        let task = Task {
            await channel.recv()
        }

        // Give recv time to start waiting
        try? await Task.sleep(for: .milliseconds(10))

        channel.close()
        let result = await task.value

        #expect(result == nil)
    }

    @Test("Recv returns nil after close and drain")
    func testRecvNilAfterCloseDrain() async {
        let channel = Channel<Int>()

        channel.send(1)
        channel.send(2)
        channel.close()

        let first = await channel.recv()
        let second = await channel.recv()
        let third = await channel.recv()

        #expect(first == 1)
        #expect(second == 2)
        #expect(third == nil)
    }

    @Test("AsyncSequence iteration")
    func testAsyncSequence() async {
        let channel = Channel<Int>()

        for i in 0..<5 {
            channel.send(i)
        }
        channel.close()

        var received: [Int] = []
        for await value in channel {
            received.append(value)
        }

        #expect(received == [0, 1, 2, 3, 4])
    }

    @Test("Drops new messages when full")
    func testDropsNewWhenFull() async {
        let channel = Channel<Int>(capacity: 4)  // Will be rounded to 4

        // Fill buffer
        for i in 0..<4 {
            channel.send(i)
        }

        // Overflow - should drop new messages (lock-free can't drop oldest)
        channel.send(100)
        channel.send(101)

        #expect(channel.droppedCount == 2)

        // Should receive 0, 1, 2, 3 (dropped 100 and 101)
        let first = await channel.recv()
        let second = await channel.recv()
        let third = await channel.recv()
        let fourth = await channel.recv()

        #expect(first == 0)
        #expect(second == 1)
        #expect(third == 2)
        #expect(fourth == 3)
    }

    @Test("Capacity rounds to power of 2")
    func testCapacityRounding() async {
        let channel = Channel<Int>(capacity: 5)

        // Should round to 8, so we can send 8 without drops
        for i in 0..<8 {
            channel.send(i)
        }

        #expect(channel.droppedCount == 0)

        // 9th should cause a drop
        channel.send(8)
        #expect(channel.droppedCount == 1)
    }

    @Test("High throughput producer-consumer")
    func testHighThroughput() async {
        let channel = Channel<Int>(capacity: 1024)
        let messageCount = 10_000

        // Producer task
        let producer = Task {
            for i in 0..<messageCount {
                channel.send(i)
            }
            channel.close()
        }

        // Consumer
        var received = 0
        for await _ in channel {
            received += 1
        }

        await producer.value

        // Some messages may be dropped if producer is faster than consumer
        #expect(received + Int(channel.droppedCount) == messageCount)
    }

    @Test("isClosed reflects state")
    func testIsClosedState() async {
        let channel = Channel<Int>()

        #expect(channel.isClosed == false)

        channel.close()

        #expect(channel.isClosed == true)
    }
}
