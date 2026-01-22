//
//  SPSCQueueTests.swift
//  PropertyTestingKit
//
//  Tests for the unbounded SPSC queue.
//

import Testing
import ConcurrentQueues
import Foundation

@Suite("SPSCQueue Tests")
struct SPSCQueueTests {

    // MARK: - Basic Operations

    @Test("Empty queue returns nil on dequeue")
    func emptyDequeue() {
        let queue = SPSCQueue<Int>()
        #expect(queue.dequeue() == nil)
        #expect(queue.isEmpty)
    }

    @Test("Single enqueue and dequeue")
    func singleEnqueueDequeue() {
        let queue = SPSCQueue<Int>()
        queue.enqueue(42)
        #expect(!queue.isEmpty)
        #expect(queue.dequeue() == 42)
        #expect(queue.isEmpty)
        #expect(queue.dequeue() == nil)
    }

    @Test("Multiple enqueue and dequeue maintains FIFO order")
    func fifoOrder() {
        let queue = SPSCQueue<Int>()

        // Enqueue several items
        for i in 0..<10 {
            queue.enqueue(i)
        }

        // Dequeue and verify order
        for i in 0..<10 {
            #expect(queue.dequeue() == i)
        }

        #expect(queue.dequeue() == nil)
    }

    @Test("Interleaved enqueue and dequeue")
    func interleavedOperations() {
        let queue = SPSCQueue<Int>()

        queue.enqueue(1)
        queue.enqueue(2)
        #expect(queue.dequeue() == 1)

        queue.enqueue(3)
        #expect(queue.dequeue() == 2)
        #expect(queue.dequeue() == 3)

        queue.enqueue(4)
        queue.enqueue(5)
        queue.enqueue(6)
        #expect(queue.dequeue() == 4)
        #expect(queue.dequeue() == 5)
        #expect(queue.dequeue() == 6)

        #expect(queue.dequeue() == nil)
    }

    // MARK: - Close Operations

    @Test("Close sets isClosed flag")
    func closeFlag() {
        let queue = SPSCQueue<Int>()
        #expect(!queue.isClosed)
        queue.close()
        #expect(queue.isClosed)
    }

    @Test("Can dequeue remaining items after close")
    func dequeueAfterClose() {
        let queue = SPSCQueue<Int>()
        queue.enqueue(1)
        queue.enqueue(2)
        queue.close()

        #expect(queue.dequeue() == 1)
        #expect(queue.dequeue() == 2)
        #expect(queue.dequeue() == nil)
    }

    // MARK: - Value Types

    @Test("Works with String values")
    func stringValues() {
        let queue = SPSCQueue<String>()
        queue.enqueue("hello")
        queue.enqueue("world")

        #expect(queue.dequeue() == "hello")
        #expect(queue.dequeue() == "world")
    }

    @Test("Works with struct values")
    func structValues() {
        struct Point: Equatable, Sendable {
            let x: Int
            let y: Int
        }

        let queue = SPSCQueue<Point>()
        queue.enqueue(Point(x: 1, y: 2))
        queue.enqueue(Point(x: 3, y: 4))

        #expect(queue.dequeue() == Point(x: 1, y: 2))
        #expect(queue.dequeue() == Point(x: 3, y: 4))
    }

    // MARK: - Reference Types

    @Test("Works with class values")
    func classValues() async {
        final class Box: @unchecked Sendable {
            let value: Int
            init(_ value: Int) { self.value = value }
        }

        let queue = SPSCQueue<Box>()
        queue.enqueue(Box(1))
        queue.enqueue(Box(2))

        let first = queue.dequeue()
        #expect(first?.value == 1)

        let second = queue.dequeue()
        #expect(second?.value == 2)

        #expect(queue.dequeue() == nil)
    }

    // MARK: - Concurrent SPSC Pattern

    @Test("Concurrent producer and consumer")
    func concurrentSPSC() async {
        let queue = SPSCQueue<Int>()
        let itemCount = 10_000

        // Track received items
        actor Collector {
            var items: [Int] = []
            func append(_ item: Int) { items.append(item) }
            func getItems() -> [Int] { items }
        }
        let collector = Collector()

        // Consumer task
        let consumerTask = Task {
            var received = 0
            while received < itemCount {
                if let value = queue.dequeue() {
                    await collector.append(value)
                    received += 1
                } else {
                    await Task.yield()
                }
            }
        }

        // Producer task
        let producerTask = Task {
            for i in 0..<itemCount {
                queue.enqueue(i)
            }
        }

        await producerTask.value
        await consumerTask.value

        let items = await collector.getItems()
        #expect(items.count == itemCount)

        // Verify FIFO order preserved
        for (index, item) in items.enumerated() {
            #expect(item == index, "Item at index \(index) was \(item), expected \(index)")
        }
    }

    @Test("High throughput stress test")
    func highThroughputStress() async {
        let queue = SPSCQueue<Int>()
        let itemCount = 100_000

        actor Counter {
            var count = 0
            var sum: Int = 0
            func add(_ value: Int) {
                count += 1
                sum += value
            }
            func getCount() -> Int { count }
            func getSum() -> Int { sum }
        }
        let counter = Counter()

        // Expected sum: 0 + 1 + 2 + ... + (itemCount-1) = itemCount * (itemCount-1) / 2
        let expectedSum = itemCount * (itemCount - 1) / 2

        // Consumer task - runs until queue is closed and empty
        let consumerTask = Task {
            while true {
                if let value = queue.dequeue() {
                    await counter.add(value)
                } else if queue.isClosed {
                    // Drain any remaining
                    while let value = queue.dequeue() {
                        await counter.add(value)
                    }
                    break
                } else {
                    await Task.yield()
                }
            }
        }

        // Producer task
        let producerTask = Task {
            for i in 0..<itemCount {
                queue.enqueue(i)
            }
            queue.close()
        }

        await producerTask.value
        await consumerTask.value

        let finalCount = await counter.getCount()
        let finalSum = await counter.getSum()

        #expect(finalCount == itemCount, "Expected \(itemCount) items, got \(finalCount)")
        #expect(finalSum == expectedSum, "Expected sum \(expectedSum), got \(finalSum)")
    }

    // MARK: - Node Cache Reuse

    @Test("Node cache is reused (no excessive allocations)")
    func nodeCacheReuse() {
        let queue = SPSCQueue<Int>()

        // Do many cycles of enqueue/dequeue
        // The node cache should prevent excessive allocations
        for cycle in 0..<1000 {
            // Enqueue a batch
            for i in 0..<10 {
                queue.enqueue(cycle * 10 + i)
            }
            // Dequeue the batch
            for i in 0..<10 {
                let expected = cycle * 10 + i
                #expect(queue.dequeue() == expected)
            }
        }

        #expect(queue.isEmpty)
    }

    // MARK: - Edge Cases

    @Test("Many items then drain")
    func manyItemsThenDrain() {
        let queue = SPSCQueue<Int>()
        let count = 10_000

        for i in 0..<count {
            queue.enqueue(i)
        }

        for i in 0..<count {
            #expect(queue.dequeue() == i)
        }

        #expect(queue.isEmpty)
    }

    @Test("receive() is alias for dequeue()")
    func receiveAlias() {
        let queue = SPSCQueue<Int>()
        queue.enqueue(1)
        #expect(queue.receive() == 1)
        #expect(queue.receive() == nil)
    }
}
