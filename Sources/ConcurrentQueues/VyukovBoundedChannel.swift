//
//  VyukovBoundedChannel.swift
//  PropertyTestingKit
//
//  Vyukov's bounded MPSC queue using sequence numbers.
//  Based on: https://www.1024cores.net/home/lock-free-algorithms/queues/bounded-mpmc-queue
//
//  Optimized for MPSC: consumer uses plain loads instead of CAS.
//
//  ## Key Design
//
//  Each slot has a sequence number that encodes:
//  - sequence == pos: slot ready for enqueue at position `pos`
//  - sequence == pos + 1: slot has data, ready for dequeue
//  - sequence == pos + mask + 1: slot ready for enqueue in next cycle
//
//  ## Trade-offs vs SpinChannel
//
//  - **Pro**: Single struct per slot (better cache locality)
//  - **Pro**: No separate "written" array
//  - **Pro**: Sequence number elegantly handles cycle detection
//  - **Con**: Slightly more complex logic
//

import Atomics
import Foundation

/// A bounded MPSC channel using Vyukov's sequence number technique.
///
/// This channel achieves excellent performance by using a per-slot sequence
/// number that tracks both readiness and cycle count in a single atomic.
public final class VyukovBoundedChannel<Element: Sendable>: @unchecked Sendable {
    // Each cell contains the sequence number and data together
    // for optimal cache locality
    private struct Cell {
        var sequence: ManagedAtomic<UInt64>
        var data: Element?

        init(sequence: UInt64) {
            self.sequence = ManagedAtomic(sequence)
            self.data = nil
        }
    }

    private let buffer: UnsafeMutablePointer<Cell>
    private let mask: UInt64
    private let capacity: Int

    // Padded to separate cache lines
    // enqueue_pos for producers, dequeue_pos for consumer
    private let enqueuePos: ManagedAtomic<UInt64>
    private let dequeuePos: ManagedAtomic<UInt64>

    // Closed flag
    private let _closed: ManagedAtomic<Bool>

    /// Whether the channel has been closed.
    public var isClosed: Bool {
        _closed.load(ordering: .acquiring)
    }

    /// Creates a new Vyukov bounded channel with the specified capacity.
    public init(capacity: Int = 1024) {
        let actualCapacity = capacity.nextPowerOf2()
        self.capacity = actualCapacity
        self.mask = UInt64(actualCapacity - 1)

        // Allocate buffer
        self.buffer = .allocate(capacity: actualCapacity)

        // Initialize each cell with its sequence number
        for i in 0..<actualCapacity {
            buffer.advanced(by: i).initialize(to: Cell(sequence: UInt64(i)))
        }

        self.enqueuePos = ManagedAtomic(0)
        self.dequeuePos = ManagedAtomic(0)
        self._closed = ManagedAtomic(false)
    }

    deinit {
        buffer.deinitialize(count: capacity)
        buffer.deallocate()
    }

    /// Sends a message to the channel (lock-free, may retry on contention).
    ///
    /// If the buffer is full, the message is dropped.
    @inline(__always)
    public func send(_ element: consuming Element) {
        var pos = enqueuePos.load(ordering: .relaxed)

        while true {
            let index = Int(pos & mask)
            let cell = buffer.advanced(by: index)
            let seq = cell.pointee.sequence.load(ordering: .acquiring)

            let dif = Int64(bitPattern: seq) - Int64(bitPattern: pos)

            if dif == 0 {
                // Slot is ready for this position - try to claim it
                let (exchanged, original) = enqueuePos.weakCompareExchange(
                    expected: pos,
                    desired: pos &+ 1,
                    successOrdering: .relaxed,
                    failureOrdering: .relaxed
                )

                if exchanged {
                    // We claimed the slot - write data and mark as filled
                    cell.pointee.data = element
                    cell.pointee.sequence.store(pos &+ 1, ordering: .releasing)
                    return
                }
                // Another producer won - retry with their position
                pos = original
            } else if dif < 0 {
                // Buffer is full (sequence is from previous cycle)
                // Spin and retry - backpressure instead of dropping
                pos = enqueuePos.load(ordering: .relaxed)
            } else {
                // Slot not ready yet - reload position and retry
                pos = enqueuePos.load(ordering: .relaxed)
            }
        }
    }

    /// Attempts to receive a message without blocking.
    ///
    /// Optimized for single consumer - no CAS needed.
    @inline(__always)
    public func tryRecv() -> sending Element? {
        let pos = dequeuePos.load(ordering: .relaxed)
        let index = Int(pos & mask)
        let cell = buffer.advanced(by: index)
        let seq = cell.pointee.sequence.load(ordering: .acquiring)

        let dif = Int64(bitPattern: seq) - Int64(bitPattern: pos &+ 1)

        if dif == 0 {
            // Slot has data for this position
            let element = cell.pointee.data
            cell.pointee.data = nil

            // Mark slot as free for next cycle
            // sequence = pos + mask + 1 = pos + capacity
            cell.pointee.sequence.store(pos &+ mask &+ 1, ordering: .releasing)

            // Advance consumer position (single consumer, no CAS needed)
            dequeuePos.store(pos &+ 1, ordering: .releasing)

            return element
        }

        // Queue is empty or producer is mid-write
        return nil
    }

    /// Receives a message, spinning until one is available.
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

    /// Closes the channel.
    public func close() {
        _closed.store(true, ordering: .releasing)
    }
}

// MARK: - Protocol Conformance

extension VyukovBoundedChannel: RelaxedQueue {}

extension VyukovBoundedChannel: Sequence {
    public func makeIterator() -> VyukovBoundedChannelIterator<Element> {
        VyukovBoundedChannelIterator(channel: self)
    }
}

public struct VyukovBoundedChannelIterator<Element: Sendable>: IteratorProtocol {
    let channel: VyukovBoundedChannel<Element>

    public mutating func next() -> Element? {
        channel.recv()
    }
}
