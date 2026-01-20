//
//  MultiQueue.swift
//  PropertyTestingKit
//
//  A relaxed queue using multiple partial queues with random selection.
//
//  ## Algorithm
//
//  Instead of one queue, maintain c*p partial queues (c > 1, p = expected threads).
//  - Enqueue: Insert into a randomly selected partial queue
//  - Dequeue: Sample 2 random queues, take from the one with more elements
//
//  The "power of two choices" principle ensures good load balancing without
//  strict coordination. Since there are more queues than threads, contention
//  is minimized.
//
//  ## Reference
//
//  Based on: "MultiQueues: Simpler, Faster, and Better Relaxed Concurrent Priority Queues"
//  https://arxiv.org/pdf/1411.1209
//

import Atomics
import Foundation

/// A relaxed queue using multiple partial queues with random selection.
///
/// Achieves high throughput by distributing elements across many partial queues,
/// reducing contention. Elements may be dequeued out of global FIFO order.
public final class MultiQueue<Element: Sendable>: @unchecked Sendable, RelaxedQueue {

    /// A single partial queue (simple ring buffer)
    private final class PartialQueue: @unchecked Sendable {
        private let buffer: UnsafeMutablePointer<Element?>
        private let capacity: Int
        private let mask: Int

        private let head: ManagedAtomic<Int>
        private let tail: ManagedAtomic<Int>
        private let lock = NSLock()

        var count: Int {
            let h = head.load(ordering: .relaxed)
            let t = tail.load(ordering: .relaxed)
            return t - h
        }

        init(capacity: Int) {
            self.capacity = capacity.nextPowerOf2()
            self.mask = self.capacity - 1
            self.buffer = .allocate(capacity: self.capacity)
            self.buffer.initialize(repeating: nil, count: self.capacity)
            self.head = ManagedAtomic(0)
            self.tail = ManagedAtomic(0)
        }

        deinit {
            buffer.deinitialize(count: capacity)
            buffer.deallocate()
        }

        /// Attempts to enqueue an element. Returns false if full.
        func tryEnqueue(_ element: Element) -> Bool {
            lock.lock()
            defer { lock.unlock() }

            let t = tail.load(ordering: .relaxed)
            let h = head.load(ordering: .relaxed)

            if t - h >= capacity {
                return false // Full
            }

            buffer[t & mask] = element
            tail.store(t + 1, ordering: .releasing)
            return true
        }

        /// Attempts to dequeue an element. Returns nil if empty.
        func tryDequeue() -> Element? {
            lock.lock()
            defer { lock.unlock() }

            let h = head.load(ordering: .relaxed)
            let t = tail.load(ordering: .relaxed)

            if h >= t {
                return nil // Empty
            }

            let element = buffer[h & mask]
            buffer[h & mask] = nil
            head.store(h + 1, ordering: .releasing)
            return element
        }
    }

    private let queues: [PartialQueue]
    private let queueCount: Int

    private let _closed: ManagedAtomic<Bool>

    // Thread-local RNG for random queue selection
    // Using a simple xorshift for speed
    private let rngState: ManagedAtomic<UInt64>

    public var isClosed: Bool {
        _closed.load(ordering: .acquiring)
    }

    /// Creates a MultiQueue.
    ///
    /// - Parameters:
    ///   - queueCount: Number of partial queues. Should be > expected thread count.
    ///                 Default is 16.
    ///   - partialCapacity: Capacity of each partial queue. Default 64.
    public init(queueCount: Int = 16, partialCapacity: Int = 64) {
        precondition(queueCount >= 2, "Need at least 2 partial queues")

        self.queueCount = queueCount
        self.queues = (0..<queueCount).map { _ in PartialQueue(capacity: partialCapacity) }
        self._closed = ManagedAtomic(false)

        // Seed RNG with current time
        let seed = UInt64(DispatchTime.now().uptimeNanoseconds)
        self.rngState = ManagedAtomic(seed == 0 ? 1 : seed)
    }

    /// Fast xorshift64 random number generator
    private func nextRandom() -> UInt64 {
        var state = rngState.load(ordering: .relaxed)
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        rngState.store(state, ordering: .relaxed)
        return state
    }

    /// Selects a random queue index
    private func randomQueueIndex() -> Int {
        Int(nextRandom() % UInt64(queueCount))
    }

    @inline(__always)
    public func send(_ element: consuming Element) {
        // Spin-wait until we find a queue with space
        while true {
            let index = randomQueueIndex()
            if queues[index].tryEnqueue(element) {
                return
            }
        }
    }

    @inline(__always)
    public func tryRecv() -> sending Element? {
        // Power of two choices: sample 2 random queues, take from fuller one
        let index1 = randomQueueIndex()
        var index2 = randomQueueIndex()

        // Ensure we pick two different queues if possible
        if index2 == index1 && queueCount > 1 {
            index2 = (index1 + 1) % queueCount
        }

        let count1 = queues[index1].count
        let count2 = queues[index2].count

        // Try the fuller queue first
        let (first, second) = count1 >= count2 ? (index1, index2) : (index2, index1)

        if let element = queues[first].tryDequeue() {
            return element
        }

        if let element = queues[second].tryDequeue() {
            return element
        }

        // Both empty - try all queues as fallback
        for i in 0..<queueCount {
            if let element = queues[i].tryDequeue() {
                return element
            }
        }

        return nil
    }

    @inline(__always)
    public func recv() -> sending Element? {
        while true {
            if let element = tryRecv() {
                return element
            }

            if _closed.load(ordering: .acquiring) {
                return tryRecv()
            }
        }
    }

    public func close() {
        _closed.store(true, ordering: .releasing)
    }
}

// MARK: - Sequence Conformance

extension MultiQueue: Sequence {
    public func makeIterator() -> MultiQueueIterator<Element> {
        MultiQueueIterator(queue: self)
    }
}

public struct MultiQueueIterator<Element: Sendable>: IteratorProtocol {
    let queue: MultiQueue<Element>

    public mutating func next() -> Element? {
        queue.recv()
    }
}
