//
//  RelaxedQueueTests.swift
//  PropertyTestingKitTests
//
//  Shared test suite for all RelaxedQueue implementations.
//  Tests correctness properties that all implementations must satisfy.
//

import Testing
import Foundation
@testable import ConcurrentQueues

// MARK: - Test Helpers

/// Creates all queue implementations for parameterized testing
func allQueueImplementations<Element: Sendable>(
    capacity: Int = 64,
    of type: Element.Type = Element.self
) -> [(name: String, queue: any RelaxedQueue<Element>)] {
    [
        ("VyukovBoundedChannel", VyukovBoundedChannel<Element>(capacity: capacity)),
        ("RelaxedBoundedChannel", RelaxedBoundedChannel<Element>(capacity: capacity)),
        // KFIFOQueue is unbounded and doesn't conform to RelaxedQueue protocol
        ("MultiQueue", MultiQueue<Element>(queueCount: 8, partialCapacity: capacity / 8)),
        ("RCQSQueue", RCQSQueue<Element>(capacity: capacity)),
        ("SegmentQueue", SegmentQueue<Element>(segmentSize: 8, capacity: capacity)),
    ]
}

// MARK: - Basic Functionality Tests

@Suite("RelaxedQueue - Basic Operations")
struct RelaxedQueueBasicTests {

    @Test("Send and receive single element", arguments: [
//        "VyukovBoundedChannel",
//        "RelaxedBoundedChannel",
//        "KFifoQueue",
//        "MultiQueue",
        "RCQSQueue",
//        "SegmentQueue"
    ])
    func sendReceiveSingle(queueName: String) {
        let queues = allQueueImplementations(of: Int.self)
        guard let (_, queue) = queues.first(where: { $0.name == queueName }) else {
            Issue.record("Queue not found: \(queueName)")
            return
        }

        queue.send(42)
        let received = queue.tryRecv()

        #expect(received == 42, "\(queueName): Expected 42, got \(String(describing: received))")
    }

    @Test("Send and receive multiple elements", arguments: [
//        "VyukovBoundedChannel",
//        "RelaxedBoundedChannel",
//        "KFifoQueue",
//        "MultiQueue",
        "RCQSQueue",
//        "SegmentQueue"
    ])
    func sendReceiveMultiple(queueName: String) {
        let queues = allQueueImplementations(of: Int.self)
        guard let (_, queue) = queues.first(where: { $0.name == queueName }) else {
            Issue.record("Queue not found: \(queueName)")
            return
        }

        let count = 20
        for i in 0..<count {
            queue.send(i)
        }

        var received: [Int] = []
        while let value = queue.tryRecv() {
            received.append(value)
        }

        // All elements should be received (relaxed order OK)
        #expect(received.count == count, "\(queueName): Expected \(count) elements, got \(received.count)")
        #expect(Set(received) == Set(0..<count), "\(queueName): Missing elements")
    }

    @Test("tryRecv returns nil when empty", arguments: [
//        "VyukovBoundedChannel",
//        "RelaxedBoundedChannel",
//        "KFifoQueue",
//        "MultiQueue",
        "RCQSQueue",
//        "SegmentQueue"
    ])
    func tryRecvEmpty(queueName: String) {
        let queues = allQueueImplementations(of: Int.self)
        guard let (_, queue) = queues.first(where: { $0.name == queueName }) else {
            Issue.record("Queue not found: \(queueName)")
            return
        }

        #expect(queue.tryRecv() == nil, "\(queueName): Expected nil from empty queue")
    }

    @Test("Close channel stops recv", arguments: [
//        "VyukovBoundedChannel",
//        "RelaxedBoundedChannel",
//        "KFifoQueue",
//        "MultiQueue",
        "RCQSQueue",
//        "SegmentQueue"
    ])
    func closeChannel(queueName: String) {
        let queues = allQueueImplementations(of: Int.self)
        guard let (_, queue) = queues.first(where: { $0.name == queueName }) else {
            Issue.record("Queue not found: \(queueName)")
            return
        }

        queue.send(1)
        queue.close()

        #expect(queue.isClosed, "\(queueName): Should be closed")
        #expect(queue.tryRecv() == 1, "\(queueName): Should receive buffered element")
        #expect(queue.tryRecv() == nil, "\(queueName): Should return nil after drained")
    }
}

// MARK: - Capacity and Overflow Tests

@Suite("RelaxedQueue - Capacity")
struct RelaxedQueueCapacityTests {

//    @Test("Message accounting: sent == received (concurrent SPSC)", arguments: [
////        "VyukovBoundedChannel",
////        "RelaxedBoundedChannel",
////        "KFifoQueue",
//        "RCQSQueue",
////        "SegmentQueue"
//    ])
//    func messageAccountingConcurrent(queueName: String) async {
//        let capacity = 4096
//        let sentCount = 100_000
//
//        // Create queue based on name
//        let queues: [(name: String, queue: any RelaxedQueue<Int>)] = [
//            ("VyukovBoundedChannel", VyukovBoundedChannel<Int>(capacity: capacity)),
//            ("RelaxedBoundedChannel", RelaxedBoundedChannel<Int>(capacity: capacity)),
//            ("KFifoQueue", KFifoQueue<Int>(k: 8, capacity: capacity)),
//            ("RCQSQueue", RCQSQueue<Int>(capacity: capacity)),
//            ("SegmentQueue", SegmentQueue<Int>(segmentSize: 8, capacity: capacity)),
//        ]
//
//        guard let (_, queue) = queues.first(where: { $0.name == queueName }) else {
//            Issue.record("Queue not found: \(queueName)")
//            return
//        }
//
//        let receivedCounter = SyncBox<Int>(0)
//
//        await withTaskGroup { group in
//            group.addTask {
//                for i in 0..<sentCount {
//                    queue.send(i)
//                }
//                queue.close()
//            }
//
//            group.addTask {
//                while let _ = queue.recv() {
//                    receivedCounter.update { t in t += 1 }
//                }
//            }
//
//            await group.waitForAll()
//        }
//
//        let receivedCount = receivedCounter.value
//
//        #expect(
//            receivedCount == sentCount,
//            "\(queueName): Message mismatch - sent \(sentCount), received \(receivedCount)"
//        )
//    }

    @Test("real")
    func real() async {
        let capacity: UInt = 4096
        let sentCount: UInt = 100_000

        let queue = RCQChannel<UInt>(size: capacity)

        let receivedCounter = SyncBox<Int>(0)
        let sentCounter = SyncBox<Int>(0)

        await withTaskGroup { group in
            group.addTask {
                while let _ = queue.receive() {
                    receivedCounter.update { t in t += 1 }
                }
            }

            group.addTask {
                for i in 0..<sentCount {
                    queue.send(i)
                    sentCounter.update { t in t += 1 }
                }
                queue.close()
            }

            await group.waitForAll()
        }

        #expect(
            receivedCounter.value == sentCounter.value
        )
    }

//    @Test("Wrap around works correctly", arguments: [
////        "VyukovBoundedChannel",
////        "RelaxedBoundedChannel",
////        "KFifoQueue",
////        "MultiQueue",
//        "RCQSQueue",
////        "SegmentQueue"
//    ])
//    func wrapAround(queueName: String) {
//        let capacity = 8
//        let queues: [(name: String, queue: any RelaxedQueue<Int>)] = [
//            ("VyukovBoundedChannel", VyukovBoundedChannel<Int>(capacity: capacity)),
//            ("RelaxedBoundedChannel", RelaxedBoundedChannel<Int>(capacity: capacity)),
//            ("KFifoQueue", KFifoQueue<Int>(k: 4, capacity: capacity)),
//            ("MultiQueue", MultiQueue<Int>(queueCount: 4, partialCapacity: 4)),
//            ("RCQSQueue", RCQSQueue<Int>(capacity: capacity)),
//            ("SegmentQueue", SegmentQueue<Int>(segmentSize: 4, capacity: capacity)),
//        ]
//
//        guard let (_, queue) = queues.first(where: { $0.name == queueName }) else {
//            Issue.record("Queue not found: \(queueName)")
//            return
//        }
//
//        // Multiple fill/drain cycles to test wrap-around
//        for round in 0..<10 {
//            let batchSize = 4
//            var sent: [Int] = []
//
//            for i in 0..<batchSize {
//                let value = round * batchSize + i
//                queue.send(value)
//                sent.append(value)
//            }
//
//            var received: [Int] = []
//            while let value = queue.tryRecv() {
//                received.append(value)
//            }
//
//            #expect(
//                Set(received) == Set(sent),
//                "\(queueName) round \(round): Expected \(Set(sent)), got \(Set(received))"
//            )
//        }
//    }
}

// MARK: - Throughput Tests

@Suite("RelaxedQueue - Throughput")
struct RelaxedQueueThroughputTests {

//    @Test("High throughput SPSC", arguments: [
////        "VyukovBoundedChannel",
////        "RelaxedBoundedChannel",
////        "KFifoQueue",
////        "MultiQueue",
//        "RCQSQueue",
////        "SegmentQueue"
//    ])
//    func spscThroughput(queueName: String) {
//        let capacity = 1024
//        let queues: [(name: String, queue: any RelaxedQueue<Int>)] = [
//            ("VyukovBoundedChannel", VyukovBoundedChannel<Int>(capacity: capacity)),
//            ("RelaxedBoundedChannel", RelaxedBoundedChannel<Int>(capacity: capacity)),
//            ("KFifoQueue", KFifoQueue<Int>(k: 16, capacity: capacity)),
//            ("MultiQueue", MultiQueue<Int>(queueCount: 8, partialCapacity: capacity / 8)),
//            ("RCQSQueue", RCQSQueue<Int>(capacity: capacity)),
//            ("SegmentQueue", SegmentQueue<Int>(segmentSize: 16, capacity: capacity)),
//        ]
//
//        guard let (_, queue) = queues.first(where: { $0.name == queueName }) else {
//            Issue.record("Queue not found: \(queueName)")
//            return
//        }
//
//        let messageCount = 500
//
//        // Send all messages
//        for i in 0..<messageCount {
//            queue.send(i)
//        }
//
//        // Receive all messages
//        var received: Set<Int> = []
//        while let value = queue.tryRecv() {
//            received.insert(value)
//        }
//
//        #expect(
//            received.count == messageCount,
//            "\(queueName): Expected \(messageCount), got \(received.count)"
//        )
//    }
//
//    @Test("Interleaved send/recv", arguments: [
////        "VyukovBoundedChannel",
////        "RelaxedBoundedChannel",
////        "KFifoQueue",
////        "MultiQueue",
//        "RCQSQueue",
////        "SegmentQueue"
//    ])
//    func interleavedSendRecv(queueName: String) {
//        let queues = allQueueImplementations(of: Int.self)
//        guard let (_, queue) = queues.first(where: { $0.name == queueName }) else {
//            Issue.record("Queue not found: \(queueName)")
//            return
//        }
//
//        var received: [Int] = []
//
//        for i in 0..<100 {
//            queue.send(i)
//            if let value = queue.tryRecv() {
//                received.append(value)
//            }
//        }
//
//        // Drain remaining
//        while let value = queue.tryRecv() {
//            received.append(value)
//        }
//
//        #expect(
//            Set(received) == Set(0..<100),
//            "\(queueName): Missing elements in interleaved test"
//        )
//    }
}

//// MARK: - Relaxation Tests
//
//@Suite("RelaxedQueue - Relaxation Properties")
//struct RelaxedQueueRelaxationTests {
//
//    @Test("All elements are eventually received", arguments: [
////        "VyukovBoundedChannel",
////        "RelaxedBoundedChannel",
////        "KFifoQueue",
////        "MultiQueue",
//        "RCQSQueue",
////        "SegmentQueue"
//    ])
//    func allElementsReceived(queueName: String) {
//        let queues = allQueueImplementations(of: Int.self)
//        guard let (_, queue) = queues.first(where: { $0.name == queueName }) else {
//            Issue.record("Queue not found: \(queueName)")
//            return
//        }
//
//        let count = 50
//        var sent: Set<Int> = []
//
//        for i in 0..<count {
//            queue.send(i)
//            sent.insert(i)
//        }
//
//        var received: Set<Int> = []
//        while let value = queue.tryRecv() {
//            received.insert(value)
//        }
//
//        // All sent elements should be received (order may differ)
//        #expect(received == sent, "\(queueName): Not all elements received")
//    }
//
//    @Test("No duplicate elements", arguments: [
////        "VyukovBoundedChannel",
////        "RelaxedBoundedChannel",
////        "KFifoQueue",
////        "MultiQueue",
//        "RCQSQueue",
////        "SegmentQueue"
//    ])
//    func noDuplicates(queueName: String) {
//        let queues = allQueueImplementations(of: Int.self)
//        guard let (_, queue) = queues.first(where: { $0.name == queueName }) else {
//            Issue.record("Queue not found: \(queueName)")
//            return
//        }
//
//        let count = 50
//        for i in 0..<count {
//            queue.send(i)
//        }
//
//        var received: [Int] = []
//        while let value = queue.tryRecv() {
//            received.append(value)
//        }
//
//        // Check for duplicates
//        let unique = Set(received)
//        #expect(
//            received.count == unique.count,
//            "\(queueName): Found duplicates - received \(received.count) but only \(unique.count) unique"
//        )
//    }
//
//    @Test("Rapid fill/drain cycles", arguments: [
////        "VyukovBoundedChannel",
////        "RelaxedBoundedChannel",
////        "KFifoQueue",
////        "MultiQueue",
//        "RCQSQueue",
////        "SegmentQueue"
//    ])
//    func rapidFillDrain(queueName: String) {
//        let capacity = 32
//        let queues: [(name: String, queue: any RelaxedQueue<Int>)] = [
//            ("VyukovBoundedChannel", VyukovBoundedChannel<Int>(capacity: capacity)),
//            ("RelaxedBoundedChannel", RelaxedBoundedChannel<Int>(capacity: capacity)),
//            ("KFifoQueue", KFifoQueue<Int>(k: 8, capacity: capacity)),
//            ("MultiQueue", MultiQueue<Int>(queueCount: 4, partialCapacity: 16)),
//            ("RCQSQueue", RCQSQueue<Int>(capacity: capacity)),
//            ("SegmentQueue", SegmentQueue<Int>(segmentSize: 8, capacity: capacity)),
//        ]
//
//        guard let (_, queue) = queues.first(where: { $0.name == queueName }) else {
//            Issue.record("Queue not found: \(queueName)")
//            return
//        }
//
//        for cycle in 0..<50 {
//            let batchSize = 16
//            var sent: Set<Int> = []
//
//            // Fill
//            for i in 0..<batchSize {
//                let value = cycle * batchSize + i
//                queue.send(value)
//                sent.insert(value)
//            }
//
//            // Drain
//            var received: Set<Int> = []
//            while let value = queue.tryRecv() {
//                received.insert(value)
//            }
//
//            #expect(
//                received == sent,
//                "\(queueName) cycle \(cycle): Expected \(sent), got \(received)"
//            )
//        }
//    }
//}

//// MARK: - Edge Cases
//
//@Suite("RelaxedQueue - Edge Cases")
//struct RelaxedQueueEdgeCaseTests {
//
//    @Test("Capacity 1 works", arguments: [
////        "VyukovBoundedChannel",
////        "RelaxedBoundedChannel",
////        "KFifoQueue",
//        "RCQSQueue",
////        "SegmentQueue"
//    ])
//    func capacityOne(queueName: String) {
//        // Note: MultiQueue needs at least 2 queues so skip it
//        let queues: [(name: String, queue: any RelaxedQueue<Int>)] = [
//            ("VyukovBoundedChannel", VyukovBoundedChannel<Int>(capacity: 1)),
//            ("RelaxedBoundedChannel", RelaxedBoundedChannel<Int>(capacity: 1)),
//            ("KFifoQueue", KFifoQueue<Int>(k: 1, capacity: 1)),
//            ("RCQSQueue", RCQSQueue<Int>(capacity: 1)),
//            ("SegmentQueue", SegmentQueue<Int>(segmentSize: 1, capacity: 1)),
//        ]
//
//        guard let (_, queue) = queues.first(where: { $0.name == queueName }) else {
//            Issue.record("Queue not found: \(queueName)")
//            return
//        }
//
//        queue.send(1)
//        #expect(queue.tryRecv() == 1, "\(queueName)")
//
//        queue.send(2)
//        #expect(queue.tryRecv() == 2, "\(queueName)")
//
//        queue.send(3)
//        #expect(queue.tryRecv() == 3, "\(queueName)")
//    }
//
//    @Test("recv with data available returns immediately", arguments: [
////        "VyukovBoundedChannel",
////        "RelaxedBoundedChannel",
////        "KFifoQueue",
////        "MultiQueue",
//        "RCQSQueue",
////        "SegmentQueue"
//    ])
//    func recvWithData(queueName: String) {
//        let queues = allQueueImplementations(of: Int.self)
//        guard let (_, queue) = queues.first(where: { $0.name == queueName }) else {
//            Issue.record("Queue not found: \(queueName)")
//            return
//        }
//
//        queue.send(42)
//        let received = queue.recv()
//        #expect(received == 42, "\(queueName)")
//    }
//
//    @Test("recv returns nil when closed and empty", arguments: [
////        "VyukovBoundedChannel",
////        "RelaxedBoundedChannel",
////        "KFifoQueue",
////        "MultiQueue",
//        "RCQSQueue",
////        "SegmentQueue"
//    ])
//    func recvClosedEmpty(queueName: String) {
//        let queues = allQueueImplementations(of: Int.self)
//        guard let (_, queue) = queues.first(where: { $0.name == queueName }) else {
//            Issue.record("Queue not found: \(queueName)")
//            return
//        }
//
//        queue.close()
//        let received = queue.recv()
//        #expect(received == nil, "\(queueName)")
//    }
//}

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
