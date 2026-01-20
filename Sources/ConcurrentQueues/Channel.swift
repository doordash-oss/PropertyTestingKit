//
//  Channel.swift
//  PropertyTestingKit
//
//  A high-performance MPSC (multiple-producer, single-consumer) channel
//  modeled after ZeroMQ's simple send/recv API.
//
//  ## Overview
//
//  Channel provides a message queue optimized for the common case where
//  multiple threads produce messages and one thread consumes them.
//
//  ```swift
//  let channel = Channel<Event>(capacity: 1024)
//
//  // Producer (hot path) - synchronous, non-blocking, thread-safe
//  channel.send(event)
//
//  // Consumer - async, waits for messages
//  for await event in channel {
//      process(event)
//  }
//
//  // Graceful shutdown
//  channel.close()
//  ```
//
//  ## Limitations
//
//  - **Single-consumer only**: Using multiple consumers concurrently is
//    undefined behavior. Multiple producers are supported.
//
//  - **Lossy when full**: When the ring buffer is full, `send()` drops the
//    new message (not the oldest). This is a trade-off for lock-free operation.
//    The producer never blocks, which is critical for hot paths. If you need
//    backpressure or FIFO drops, use a different synchronization primitive.
//
//  - **Fixed capacity**: The buffer size is set at initialization and cannot
//    grow. Choose a capacity large enough for your expected burst size.
//

import Atomics
import Foundation

/// A high-performance lock-free MPSC channel using a ring buffer.
///
/// - Warning: This channel is designed for multiple producers but exactly one consumer.
///   Using multiple consumers concurrently is undefined behavior.
public final class Channel<Element: Sendable>: @unchecked Sendable {
    private let buffer: UnsafeMutablePointer<Element?>
    private let written: UnsafeMutablePointer<ManagedAtomic<Bool>>
    private let mask: Int

    // Atomic indices - using UInt64 to avoid overflow issues
    // Head: next position to read from (consumer owns this)
    // Tail: next position to write to (reserved via CAS)
    private let head: ManagedAtomic<UInt64>
    private let tail: ManagedAtomic<UInt64>

    // Closed flag
    private let _closed: ManagedAtomic<Bool>

    // Waiter coordination - uses a lock only for the cold path (waiting)
    // Continuation returns true to retry recv(), false if channel closed
    private let waiterLock = NSLock()
    private var waiter: CheckedContinuation<Bool, Never>?
    private let hasWaiter = ManagedAtomic<Bool>(false)

    /// Whether the channel has been closed.
    public var isClosed: Bool {
        _closed.load(ordering: .acquiring)
    }

    /// Creates a new channel with the specified capacity.
    ///
    /// - Parameter capacity: The maximum number of messages the channel can buffer.
    ///   Will be rounded up to the next power of 2. Default is 1024.
    public init(capacity: Int = 1024) {
        // Round up to next power of 2 for efficient modulo
        let actualCapacity = capacity.nextPowerOf2()
        self.mask = actualCapacity - 1

        // Allocate and initialize buffer
        self.buffer = .allocate(capacity: actualCapacity)
        buffer.initialize(repeating: nil, count: actualCapacity)

        // Allocate and initialize per-slot written flags
        self.written = .allocate(capacity: actualCapacity)
        for i in 0..<actualCapacity {
            written.advanced(by: i).initialize(to: ManagedAtomic(false))
        }

        self.head = ManagedAtomic(0)
        self.tail = ManagedAtomic(0)
        self._closed = ManagedAtomic(false)
    }

    deinit {
        // Clean up any remaining elements
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .relaxed)
        for i in h..<t {
            buffer[Int(i) & mask] = nil
        }
        buffer.deinitialize(count: mask + 1)
        buffer.deallocate()

        // Deallocate written flags
        written.deinitialize(count: mask + 1)
        written.deallocate()
    }

    /// Sends a message to the channel.
    ///
    /// This method is lock-free and thread-safe for multiple producers.
    /// If the buffer is full, the message is dropped.
    ///
    /// - Parameter element: The message to send. Ownership is transferred (moved, not copied).
    public func send(_ element: consuming Element) {
        // Lock-free slot reservation using CAS
        while true {
            let t = tail.load(ordering: .relaxed)
            let h = head.load(ordering: .acquiring)

            let count = t &- h  // Wraparound-safe subtraction
            let capacity = UInt64(mask + 1)

            // Check if buffer is full
            if count >= capacity {
                // Buffer full - drop this message
                // (Can't safely drop oldest in lock-free MPSC)
                return
            }

            // Try to reserve this slot with CAS
            let (exchanged, _) = tail.compareExchange(
                expected: t,
                desired: t &+ 1,
                successOrdering: .relaxed,
                failureOrdering: .relaxed
            )

            if exchanged {
                // We got the slot - write element and mark as written
                let index = Int(t) & mask
                buffer[index] = element
                written[index].store(true, ordering: .releasing)
                break
            }
            // CAS failed - another producer got there first, retry
        }

        // Wake waiter if any (truly cold path now - skip lock if no waiter)
        if hasWaiter.load(ordering: .acquiring) {
            waiterLock.lock()
            if let continuation = waiter {
                waiter = nil
                hasWaiter.store(false, ordering: .relaxed)
                waiterLock.unlock()
                continuation.resume(returning: true)  // Signal to retry recv
            } else {
                waiterLock.unlock()
            }
        }
    }

    /// Attempts to receive a message without blocking.
    ///
    /// - Returns: The next message, or `nil` if the channel is empty or closed.
    /// - Note: This method should only be called from a single consumer thread.
    public func tryRecv() -> Element? {
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)

        if h < t {
            // Slot reserved - wait for it to be written
            let index = Int(h) & mask
            while !written[index].load(ordering: .acquiring) {
                // Spin until producer finishes writing
            }

            // Read element and clear slot
            let element = buffer[index]
            buffer[index] = nil
            written[index].store(false, ordering: .relaxed)
            head.wrappingIncrement(ordering: .releasing)
            return element
        }

        return nil
    }

    /// Receives a message from the channel.
    ///
    /// This method suspends until a message is available or the channel is closed.
    ///
    /// - Returns: The next message, or `nil` if the channel is closed and empty.
    /// - Note: This method should only be called from a single consumer thread.
    public func recv() async -> Element? {
        while true {
            // Fast path: check if there's data available
            let h = head.load(ordering: .relaxed)
            let t = tail.load(ordering: .acquiring)

            if h < t {
                // Slot reserved - wait for it to be written
                let index = Int(h) & mask
                while !written[index].load(ordering: .acquiring) {
                    // Yield to allow other tasks to run (including the producer)
                    await Task.yield()
                }

                // Read element and clear slot
                let element = buffer[index]
                buffer[index] = nil
                written[index].store(false, ordering: .relaxed)
                head.wrappingIncrement(ordering: .releasing)
                return element
            }

            // Check if closed
            if _closed.load(ordering: .acquiring) {
                return nil
            }

            // Slow path: need to wait for producer
            let shouldRetry = await withCheckedContinuation { continuation in
                waiterLock.lock()

                // Double-check after acquiring lock
                let h2 = head.load(ordering: .relaxed)
                let t2 = tail.load(ordering: .acquiring)

                if h2 < t2 {
                    // Data became available - retry the fast path
                    waiterLock.unlock()
                    continuation.resume(returning: true)
                    return
                }

                if _closed.load(ordering: .acquiring) {
                    waiterLock.unlock()
                    continuation.resume(returning: false)
                    return
                }

                // Store continuation and wait
                waiter = continuation
                hasWaiter.store(true, ordering: .releasing)
                waiterLock.unlock()
            }

            if !shouldRetry {
                return nil  // Channel closed
            }
            // Loop back to try reading again
        }
    }

    /// Closes the channel.
    ///
    /// After closing, `send()` calls are ignored and `recv()` will return `nil`
    /// once all buffered messages are consumed.
    public func close() {
        _closed.store(true, ordering: .releasing)

        // Wake any waiting consumer
        waiterLock.lock()
        if let continuation = waiter {
            waiter = nil
            hasWaiter.store(false, ordering: .relaxed)
            waiterLock.unlock()
            continuation.resume(returning: false)  // Signal closed, don't retry
        } else {
            waiterLock.unlock()
        }
    }
}

// MARK: - AsyncSequence

extension Channel: AsyncSequence {
    public typealias AsyncIterator = ChannelIterator

    public func makeAsyncIterator() -> ChannelIterator {
        ChannelIterator(channel: self)
    }

    public struct ChannelIterator: AsyncIteratorProtocol {
        let channel: Channel<Element>

        public mutating func next() async -> Element? {
            await channel.recv()
        }
    }
}

// MARK: - Helpers

extension Int {
    func nextPowerOf2() -> Int {
        guard self > 0 else { return 1 }
        guard self <= (Int.max >> 1) + 1 else { return self }
        return 1 << (Int.bitWidth - (self - 1).leadingZeroBitCount)
    }
}
