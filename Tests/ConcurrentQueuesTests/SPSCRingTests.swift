//
//  SPSCRingTests.swift
//  PropertyTestingKit
//

import Testing
@testable import ConcurrentQueues

@Suite("SPSCRing")
struct SPSCRingTests {

    // MARK: - Initialization Tests

    @Test("initializes with power of 2 capacity")
    func initPowerOf2() {
        let ring = SPSCRing<Int>(capacity: 16)
        #expect(ring.capacity == 16)
    }

    @Test("rounds up capacity to next power of 2")
    func initRoundsUp() {
        let ring = SPSCRing<Int>(capacity: 10)
        #expect(ring.capacity == 16)

        let ring2 = SPSCRing<Int>(capacity: 17)
        #expect(ring2.capacity == 32)
    }

    @Test("capacity 1 works")
    func initCapacity1() {
        let ring = SPSCRing<Int>(capacity: 1)
        #expect(ring.capacity == 1)
    }

    // MARK: - Basic Operations

    @Test("enqueue and dequeue single value")
    func enqueueDequeue() {
        let ring = SPSCRing<Int>(capacity: 4)

        ring.enqueue(42)
        let value = ring.dequeue()

        #expect(value == 42)
    }

    @Test("dequeue from empty returns nil")
    func dequeueEmpty() {
        let ring = SPSCRing<Int>(capacity: 4)
        #expect(ring.dequeue() == nil)
    }

    @Test("isEmpty is true for empty ring")
    func isEmptyTrue() {
        let ring = SPSCRing<Int>(capacity: 4)
        #expect(ring.isEmpty == true)
    }

    @Test("isEmpty is false after enqueue")
    func isEmptyFalse() {
        let ring = SPSCRing<Int>(capacity: 4)
        ring.enqueue(1)
        #expect(ring.isEmpty == false)
    }

    @Test("isEmpty is true after all dequeued")
    func isEmptyAfterDequeue() {
        let ring = SPSCRing<Int>(capacity: 4)
        ring.enqueue(1)
        ring.enqueue(2)
        _ = ring.dequeue()
        _ = ring.dequeue()
        #expect(ring.isEmpty == true)
    }

    // MARK: - FIFO Order

    @Test("maintains FIFO order")
    func fifoOrder() {
        let ring = SPSCRing<Int>(capacity: 8)

        for i in 0..<5 {
            ring.enqueue(i)
        }

        for i in 0..<5 {
            #expect(ring.dequeue() == i)
        }
    }

    // MARK: - Wraparound

    @Test("handles wraparound correctly")
    func wraparound() {
        let ring = SPSCRing<Int>(capacity: 4)

        // Fill and empty several times to test wraparound
        for round in 0..<10 {
            let base = round * 3
            ring.enqueue(base)
            ring.enqueue(base + 1)
            ring.enqueue(base + 2)

            #expect(ring.dequeue() == base)
            #expect(ring.dequeue() == base + 1)
            #expect(ring.dequeue() == base + 2)
        }
    }

    // MARK: - Full Buffer

    @Test("tryEnqueue returns false when full")
    func tryEnqueueFull() {
        let ring = SPSCRing<Int>(capacity: 4)

        // Fill to capacity (capacity - 1 slots usable in typical ring buffer)
        // Actually our implementation uses all slots
        #expect(ring.tryEnqueue(1) == true)
        #expect(ring.tryEnqueue(2) == true)
        #expect(ring.tryEnqueue(3) == true)
        #expect(ring.tryEnqueue(4) == true)

        // Should be full now
        #expect(ring.tryEnqueue(5) == false)
    }

    @Test("can enqueue after dequeue from full")
    func enqueueAfterDequeueFull() {
        let ring = SPSCRing<Int>(capacity: 4)

        // Fill
        ring.enqueue(1)
        ring.enqueue(2)
        ring.enqueue(3)
        ring.enqueue(4)

        // Dequeue one
        #expect(ring.dequeue() == 1)

        // Should be able to enqueue now
        #expect(ring.tryEnqueue(5) == true)

        // Verify order
        #expect(ring.dequeue() == 2)
        #expect(ring.dequeue() == 3)
        #expect(ring.dequeue() == 4)
        #expect(ring.dequeue() == 5)
    }

    // MARK: - Close Operations

    @Test("close sets isClosed")
    func closeSetsClosed() {
        let ring = SPSCRing<Int>(capacity: 4)
        #expect(ring.isClosed == false)

        ring.close()
        #expect(ring.isClosed == true)
    }

    @Test("receive is alias for dequeue")
    func receiveAlias() {
        let ring = SPSCRing<Int>(capacity: 4)
        ring.enqueue(42)
        #expect(ring.receive() == 42)
    }

    // MARK: - Reference Types

    @Test("handles reference types correctly")
    func referenceTypes() {
        final class Box: @unchecked Sendable {
            var value: Int
            init(_ value: Int) { self.value = value }
        }

        let ring = SPSCRing<Box>(capacity: 4)

        let box1 = Box(1)
        let box2 = Box(2)

        ring.enqueue(box1)
        ring.enqueue(box2)

        let result1 = ring.dequeue()
        let result2 = ring.dequeue()

        #expect(result1?.value == 1)
        #expect(result2?.value == 2)
    }

    // MARK: - Concurrent Tests

    @Test("producer-consumer concurrent access")
    func concurrentAccess() async {
        let ring = SPSCRing<Int>(capacity: 1024)
        let count = 10_000

        await withTaskGroup(of: Void.self) { group in
            // Producer
            group.addTask {
                for i in 0..<count {
                    ring.enqueue(i)
                }
                ring.close()
            }

            // Consumer
            group.addTask {
                var received = [Int]()
                received.reserveCapacity(count)

                while !ring.isClosed || !ring.isEmpty {
                    if let value = ring.dequeue() {
                        received.append(value)
                    }
                }

                // Verify we got all values in order
                #expect(received.count == count)
                for i in 0..<received.count {
                    #expect(received[i] == i)
                }
            }
        }
    }

    @Test("high contention with small buffer")
    func highContention() async {
        let ring = SPSCRing<Int>(capacity: 8)  // Small buffer forces blocking
        let count = 1000

        await withTaskGroup(of: Void.self) { group in
            // Producer
            group.addTask {
                for i in 0..<count {
                    ring.enqueue(i)
                }
                ring.close()
            }

            // Consumer - intentionally slow to create back-pressure
            group.addTask {
                var received = [Int]()
                received.reserveCapacity(count)

                while !ring.isClosed || !ring.isEmpty {
                    if let value = ring.dequeue() {
                        received.append(value)
                    }
                }

                #expect(received.count == count)
            }
        }
    }
}

// MARK: - Int.nextPowerOf2 Tests

@Suite("Int.nextPowerOf2")
struct NextPowerOf2Tests {

    @Test("returns same value for powers of 2")
    func powersOf2() {
        #expect(1.nextPowerOf2() == 1)
        #expect(2.nextPowerOf2() == 2)
        #expect(4.nextPowerOf2() == 4)
        #expect(8.nextPowerOf2() == 8)
        #expect(16.nextPowerOf2() == 16)
        #expect(1024.nextPowerOf2() == 1024)
    }

    @Test("rounds up non-powers of 2")
    func nonPowersOf2() {
        #expect(3.nextPowerOf2() == 4)
        #expect(5.nextPowerOf2() == 8)
        #expect(6.nextPowerOf2() == 8)
        #expect(7.nextPowerOf2() == 8)
        #expect(9.nextPowerOf2() == 16)
        #expect(100.nextPowerOf2() == 128)
        #expect(1000.nextPowerOf2() == 1024)
    }

    @Test("handles edge cases")
    func edgeCases() {
        #expect(0.nextPowerOf2() == 1)
        #expect((-1).nextPowerOf2() == 1)
    }
}
