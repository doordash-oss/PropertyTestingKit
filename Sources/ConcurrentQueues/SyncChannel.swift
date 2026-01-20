//
//  SyncChannel.swift
//  PropertyTestingKit
//
//  A synchronous blocking channel using semaphores instead of async/await.
//  Designed for dedicated worker threads that can afford to block.
//

import Atomics
import Foundation

/// A bounded MPSC channel that uses synchronous blocking instead of async/await.
///
/// This channel is optimized for scenarios where:
/// - Workers are dedicated threads that can block
/// - Low latency is more important than cooperative scheduling
/// - The overhead of async task wakeup is unacceptable
///
/// Key differences from `Channel`:
/// - `recv()` blocks the thread using a semaphore instead of suspending a task
/// - No async/await overhead on the receive path
/// - Still lock-free on the send path
public final class SyncChannel<Element: Sendable>: @unchecked Sendable {
    private let buffer: UnsafeMutablePointer<Element?>
    private let written: UnsafeMutablePointer<ManagedAtomic<Bool>>
    private let mask: Int

    // Atomic indices
    private let head: ManagedAtomic<UInt64>
    private let tail: ManagedAtomic<UInt64>

    // Closed flag
    private let _closed: ManagedAtomic<Bool>

    // Semaphore for blocking recv
    private let itemAvailable: DispatchSemaphore

    /// Whether the channel has been closed.
    public var isClosed: Bool {
        _closed.load(ordering: .acquiring)
    }

    /// Creates a new synchronous channel with the specified capacity.
    public init(capacity: Int = 1024) {
        let actualCapacity = capacity.nextPowerOf2()
        self.mask = actualCapacity - 1

        self.buffer = .allocate(capacity: actualCapacity)
        buffer.initialize(repeating: nil, count: actualCapacity)

        self.written = .allocate(capacity: actualCapacity)
        for i in 0..<actualCapacity {
            written.advanced(by: i).initialize(to: ManagedAtomic(false))
        }

        self.head = ManagedAtomic(0)
        self.tail = ManagedAtomic(0)
        self._closed = ManagedAtomic(false)
        self.itemAvailable = DispatchSemaphore(value: 0)
    }

    deinit {
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .relaxed)
        for i in h..<t {
            buffer[Int(i) & mask] = nil
        }
        buffer.deinitialize(count: mask + 1)
        buffer.deallocate()

        written.deinitialize(count: mask + 1)
        written.deallocate()
    }

    /// Sends a message to the channel (lock-free, non-blocking).
    ///
    /// If the buffer is full, the message is dropped.
    public func send(_ element: consuming Element) {
        while true {
            let t = tail.load(ordering: .relaxed)
            let h = head.load(ordering: .acquiring)

            let count = t &- h
            let capacity = UInt64(mask + 1)

            if count >= capacity {
                return
            }

            let (exchanged, _) = tail.compareExchange(
                expected: t,
                desired: t &+ 1,
                successOrdering: .relaxed,
                failureOrdering: .relaxed
            )

            if exchanged {
                let index = Int(t) & mask
                buffer[index] = element
                written[index].store(true, ordering: .releasing)
                break
            }
        }

        // Signal that an item is available
        itemAvailable.signal()
    }

    /// Attempts to receive a message without blocking.
    public func tryRecv() -> Element? {
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)

        if h < t {
            let index = Int(h) & mask
            while !written[index].load(ordering: .acquiring) {
                // Spin until producer finishes writing
            }

            let element = buffer[index]
            buffer[index] = nil
            written[index].store(false, ordering: .relaxed)
            head.wrappingIncrement(ordering: .releasing)
            return element
        }

        return nil
    }

    /// Receives a message, blocking the thread until one is available.
    ///
    /// - Returns: The next message, or `nil` if the channel is closed and empty.
    public func recv() -> Element? {
        while true {
            // Fast path: check if data available
            if let element = tryRecv() {
                return element
            }

            // Check if closed
            if _closed.load(ordering: .acquiring) {
                // Drain any remaining
                return tryRecv()
            }

            // Block until signaled
            itemAvailable.wait()

            // After waking, check closed again
            if _closed.load(ordering: .acquiring) {
                // Try one more time to get remaining data
                if let element = tryRecv() {
                    return element
                }
                return nil
            }
        }
    }

    /// Receives a message with a timeout.
    ///
    /// - Parameter timeout: Maximum time to wait.
    /// - Returns: The next message, or `nil` if timeout or closed.
    public func recv(timeout: DispatchTimeInterval) -> Element? {
        // Fast path
        if let element = tryRecv() {
            return element
        }

        if _closed.load(ordering: .acquiring) {
            return tryRecv()
        }

        let result = itemAvailable.wait(timeout: .now() + timeout)
        if result == .timedOut {
            return nil
        }

        return tryRecv()
    }

    /// Closes the channel.
    public func close() {
        _closed.store(true, ordering: .releasing)
        // Signal multiple times to wake any blocked receivers
        for _ in 0..<16 {
            itemAvailable.signal()
        }
    }
}

// MARK: - Sequence Conformance (for iteration)

extension SyncChannel: Sequence {
    public func makeIterator() -> SyncChannelIterator<Element> {
        SyncChannelIterator(channel: self)
    }
}

public struct SyncChannelIterator<Element: Sendable>: IteratorProtocol {
    let channel: SyncChannel<Element>

    public mutating func next() -> Element? {
        channel.recv()
    }
}
