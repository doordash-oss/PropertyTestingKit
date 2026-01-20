//
//  SpinChannel.swift
//  PropertyTestingKit
//
//  A channel that uses busy-spinning instead of blocking or async suspension.
//  Designed for maximum throughput when you can dedicate CPU cores.
//
//  ## Trade-offs
//
//  - **Pro**: Lowest possible latency - no syscalls, no task scheduling
//  - **Pro**: No async overhead, no semaphore overhead
//  - **Con**: Burns CPU while waiting - not suitable for variable workloads
//  - **Con**: Requires dedicated threads/cores for best results
//

import Atomics
import Foundation

/// A bounded MPSC channel that uses busy-spinning for the consumer.
///
/// This channel achieves the lowest possible latency by having the consumer
/// spin-wait for messages instead of blocking or suspending. Use this only
/// when you can dedicate a thread/core to consuming and need minimum latency.
public final class SpinChannel<Element: Sendable>: @unchecked Sendable {
    private let buffer: UnsafeMutablePointer<Element?>
    private let written: UnsafeMutablePointer<ManagedAtomic<Bool>>
    private let mask: Int

    // Atomic indices
    private let head: ManagedAtomic<UInt64>
    private let tail: ManagedAtomic<UInt64>

    // Closed flag
    private let _closed: ManagedAtomic<Bool>

    /// Whether the channel has been closed.
    public var isClosed: Bool {
        _closed.load(ordering: .acquiring)
    }

    /// Creates a new spin channel with the specified capacity.
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
    @inline(__always)
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
                return
            }
        }
    }

    /// Attempts to receive a message without blocking.
    ///
    /// Optimized for single consumer - uses plain store instead of atomic RMW.
    @inline(__always)
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
            // Single consumer optimization: plain store instead of atomic RMW
            head.store(h &+ 1, ordering: .releasing)
            return element
        }

        return nil
    }

    /// Receives a message, spinning until one is available.
    ///
    /// - Warning: This method busy-waits and will consume 100% of one CPU core
    ///   while waiting. Only use when you can dedicate a thread to consuming.
    ///
    /// - Returns: The next message, or `nil` if the channel is closed and empty.
    @inline(__always)
    public func recv() -> Element? {
        while true {
            // Try to receive
            let h = head.load(ordering: .relaxed)
            let t = tail.load(ordering: .acquiring)

            if h < t {
                let index = Int(h) & mask

                // Spin until producer finishes writing
                while !written[index].load(ordering: .acquiring) {
                    // Tight spin - producer is mid-write, should complete very soon
                }

                let element = buffer[index]
                buffer[index] = nil
                written[index].store(false, ordering: .relaxed)
                // Single consumer optimization: plain store instead of atomic RMW
                head.store(h &+ 1, ordering: .releasing)
                return element
            }

            // Check if closed
            if _closed.load(ordering: .acquiring) {
                // One final check for remaining data
                return tryRecv()
            }

            // Pure spin - keep checking for data
        }
    }

    /// Receives a message with a spin limit.
    ///
    /// - Parameter maxSpins: Maximum spin iterations before returning nil.
    /// - Returns: The next message, or `nil` if spin limit reached or closed.
    @inline(__always)
    public func recv(maxSpins: UInt32) -> Element? {
        var spins: UInt32 = 0

        while spins < maxSpins {
            if let element = tryRecv() {
                return element
            }

            if _closed.load(ordering: .acquiring) {
                return tryRecv()
            }

            spins &+= 1
        }

        return nil
    }

    /// Closes the channel.
    public func close() {
        _closed.store(true, ordering: .releasing)
        // No need to wake anyone - they're spinning and will see the flag
    }
}

// MARK: - Sequence Conformance

extension SpinChannel: Sequence {
    public func makeIterator() -> SpinChannelIterator<Element> {
        SpinChannelIterator(channel: self)
    }
}

public struct SpinChannelIterator<Element: Sendable>: IteratorProtocol {
    let channel: SpinChannel<Element>

    public mutating func next() -> Element? {
        channel.recv()
    }
}

// MARK: - AsyncSequence Conformance

extension SpinChannel: AsyncSequence {
    public typealias AsyncIterator = SpinChannelAsyncIterator<Element>

    public func makeAsyncIterator() -> SpinChannelAsyncIterator<Element> {
        SpinChannelAsyncIterator(channel: self)
    }
}

public struct SpinChannelAsyncIterator<Element: Sendable>: AsyncIteratorProtocol {
    let channel: SpinChannel<Element>

    public mutating func next() async -> Element? {
        // Use the spinning recv - this will busy-wait
        channel.recv()
    }
}
