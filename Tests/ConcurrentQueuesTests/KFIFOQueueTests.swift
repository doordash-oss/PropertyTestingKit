//
//  KFIFOQueueTests.swift
//  ConcurrentQueuesTests
//
//  Tests for the lock-free k-FIFO Queue.
//

import Testing
import Foundation
import Atomics
@testable import ConcurrentQueues

@Suite("KFIFOQueue")
struct KFIFOQueueTests {

    @Test("Enqueue and dequeue single item")
    func testEnqueueDequeueSingle() {
        let queue = KFIFOQueue<Int>(k: 4)

        let enqueued = queue.enqueue(42)
        #expect(enqueued == true)

        let dequeued = queue.dequeue()
        #expect(dequeued == 42)
    }

    @Test("Dequeue from empty queue returns nil")
    func testDequeueEmptyReturnsNil() {
        let queue = KFIFOQueue<Int>(k: 4)

        let result = queue.dequeue()
        #expect(result == nil)
    }

    @Test("Enqueue multiple items and dequeue all")
    func testEnqueueDequeueMultiple() {
        let queue = KFIFOQueue<Int>(k: 8)
        let count = 100

        for i in 0..<count {
            let enqueued = queue.enqueue(i)
            #expect(enqueued == true)
        }

        var dequeued: [Int] = []
        while let value = queue.dequeue() {
            dequeued.append(value)
        }

        #expect(dequeued.count == count)
        // k-FIFO allows out-of-order within k positions, so check all values present
        #expect(Set(dequeued) == Set(0..<count))
    }

    @Test("Close prevents enqueue")
    func testCloseBlocksEnqueue() {
        let queue = KFIFOQueue<Int>(k: 4)

        queue.enqueue(1)
        queue.close()

        let enqueued = queue.enqueue(2)
        #expect(enqueued == false)
        #expect(queue.isClosed == true)
    }

    @Test("Close allows draining existing items")
    func testCloseDrainsExisting() {
        let queue = KFIFOQueue<Int>(k: 4)

        queue.enqueue(1)
        queue.enqueue(2)
        queue.enqueue(3)
        queue.close()

        var dequeued: [Int] = []
        while let value = queue.dequeue() {
            dequeued.append(value)
        }

        #expect(dequeued.count == 3)
        #expect(Set(dequeued) == Set([1, 2, 3]))
    }

    @Test("isClosed reflects state")
    func testIsClosedState() {
        let queue = KFIFOQueue<Int>(k: 4)

        #expect(queue.isClosed == false)

        queue.close()

        #expect(queue.isClosed == true)
    }

    @Test("Works with different k values")
    func testDifferentKValues() {
        for k in [1, 2, 4, 8, 16, 32] {
            let queue = KFIFOQueue<Int>(k: k)
            let count = k * 3

            for i in 0..<count {
                queue.enqueue(i)
            }

            var dequeued: [Int] = []
            while let value = queue.dequeue() {
                dequeued.append(value)
            }

            #expect(dequeued.count == count, "k=\(k) should dequeue all items")
            #expect(Set(dequeued) == Set(0..<count), "k=\(k) should have all values")
        }
    }

    @Test("Works with reference types")
    func testReferenceTypes() {
        class MyObject {
            let value: Int
            init(_ value: Int) { self.value = value }
        }

        let queue = KFIFOQueue<MyObject>(k: 4)

        let obj1 = MyObject(1)
        let obj2 = MyObject(2)
        let obj3 = MyObject(3)

        queue.enqueue(obj1)
        queue.enqueue(obj2)
        queue.enqueue(obj3)

        var dequeued: [MyObject] = []
        while let obj = queue.dequeue() {
            dequeued.append(obj)
        }

        #expect(dequeued.count == 3)
        let values = Set(dequeued.map { $0.value })
        #expect(values == Set([1, 2, 3]))
    }

    @Test("Concurrent enqueue from multiple threads")
    func testConcurrentEnqueue() async {
        let queue = KFIFOQueue<Int>(k: 16)
        let itemsPerThread = 1000
        let threadCount = 4

        await withTaskGroup(of: Void.self) { group in
            for t in 0..<threadCount {
                group.addTask {
                    for i in 0..<itemsPerThread {
                        queue.enqueue(t * itemsPerThread + i)
                    }
                }
            }
        }

        var dequeued: [Int] = []
        while let value = queue.dequeue() {
            dequeued.append(value)
        }

        let expected = threadCount * itemsPerThread
        #expect(dequeued.count == expected)
        #expect(Set(dequeued) == Set(0..<expected))
    }

    @Test("Concurrent enqueue and dequeue")
    func testConcurrentEnqueueDequeue() async {
        let queue = KFIFOQueue<Int>(k: 16)
        let itemCount = 10000

        await withTaskGroup(of: [Int].self) { group in
            // Producer
            group.addTask {
                for i in 0..<itemCount {
                    queue.enqueue(i)
                }
                return []
            }

            // Consumer - run until we get all items
            group.addTask {
                var received: [Int] = []
                var emptyCount = 0
                while received.count < itemCount {
                    if let value = queue.dequeue() {
                        received.append(value)
                        emptyCount = 0
                    } else {
                        emptyCount += 1
                        if emptyCount > 1000 {
                            // Give producer time
                            try? await Task.sleep(for: .microseconds(100))
                            emptyCount = 0
                        }
                    }
                }
                return received
            }

            var allReceived: [Int] = []
            for await result in group {
                allReceived.append(contentsOf: result)
            }

            #expect(allReceived.count == itemCount)
            #expect(Set(allReceived) == Set(0..<itemCount))
        }
    }

    @Test("Stress test with multiple producers and consumers")
    func testStressMultipleProducersConsumers() async {
        let queue = KFIFOQueue<Int>(k: 32)
        let itemsPerProducer = 500
        let producerCount = 4
        let consumerCount = 4
        let totalItems = itemsPerProducer * producerCount

        let receivedCount = ManagedAtomic<Int>(0)
        let producersDone = ManagedAtomic<Int>(0)

        await withTaskGroup(of: Void.self) { group in
            // Producers
            for p in 0..<producerCount {
                group.addTask {
                    for i in 0..<itemsPerProducer {
                        queue.enqueue(p * itemsPerProducer + i)
                    }
                    producersDone.wrappingIncrement(ordering: .relaxed)
                }
            }

            // Consumers
            for _ in 0..<consumerCount {
                group.addTask {
                    var emptyStreak = 0
                    while true {
                        if let _ = queue.dequeue() {
                            receivedCount.wrappingIncrement(ordering: .relaxed)
                            emptyStreak = 0
                        } else {
                            emptyStreak += 1
                            // Check if all producers done and queue empty
                            if producersDone.load(ordering: .relaxed) == producerCount {
                                if emptyStreak > 100 {
                                    break
                                }
                            }
                            if emptyStreak > 10 {
                                try? await Task.sleep(for: .microseconds(10))
                            }
                        }
                    }
                }
            }
        }

        let received = receivedCount.load(ordering: .relaxed)
        #expect(received == totalItems, "Expected \(totalItems), got \(received)")
    }
}
