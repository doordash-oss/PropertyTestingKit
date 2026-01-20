//
//  RelaxedBoundedChannel.swift
//  PropertyTestingKit
//
//  A bounded MPSC channel with relaxed ordering for better throughput.
//  Based on Vyukov's bounded queue but allows out-of-order consumption.
//
//  ## Key Difference from VyukovBoundedChannel
//
//  When the head slot isn't ready (producer still writing), instead of
//  waiting, we scan ahead and take the first ready element. This trades
//  strict FIFO ordering for better throughput under producer contention.
//
//  ## Sequence Number States
//
//  - seq == pos: slot ready for enqueue at position `pos`
//  - seq == pos + 1: slot has data, ready for dequeue
//  - seq == pos + 2: slot was consumed (dequeuePos hasn't caught up)
//  - seq == pos + mask + 1: slot recycled, ready for next cycle
//

import Atomics
import Foundation

/// A bounded MPSC channel with relaxed ordering for improved throughput.
///
/// Unlike strict FIFO channels, this channel may deliver elements slightly
/// out of order when producers have varying write latencies. This improves
/// throughput by not blocking on slow producers.
public final class RelaxedBoundedChannel<Element: Sendable>: @unchecked Sendable {
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

    /// How far ahead to scan for ready elements
    private let scanLimit: Int

    private let enqueuePos: ManagedAtomic<UInt64>
    private let dequeuePos: ManagedAtomic<UInt64>

    private let _closed: ManagedAtomic<Bool>

    /// Whether the channel has been closed.
    public var isClosed: Bool {
        _closed.load(ordering: .acquiring)
    }

    /// Creates a new relaxed bounded channel.
    ///
    /// - Parameters:
    ///   - capacity: Buffer capacity (rounded to power of 2). Default 1024.
    ///   - scanLimit: How far ahead to scan for ready elements. Default 16.
    public init(capacity: Int = 1024, scanLimit: Int = 16) {
        let actualCapacity = capacity.nextPowerOf2()
        self.capacity = actualCapacity
        self.mask = UInt64(actualCapacity - 1)
        self.scanLimit = scanLimit

        self.buffer = .allocate(capacity: actualCapacity)
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
        // Load the current enqueue position. This is where we'll try to write.
        // Multiple producers may read the same value here - that's fine,
        // the CAS below will resolve the race.
        var pos = enqueuePos.load(ordering: .relaxed)

        while true {
            // Map position to buffer index using bitmask (faster than modulo).
            // pos can grow unbounded, but index wraps around the ring buffer.
            let index = Int(pos & mask)
            let cell = buffer.advanced(by: index)  // O(1) pointer arithmetic

            // Load the slot's sequence number with acquire ordering.
            // This synchronizes with the consumer's release store after recycling.
            let seq = cell.pointee.sequence.load(ordering: .acquiring)

            // Compare sequence to position to determine slot state.
            // We use signed arithmetic to handle wraparound correctly.
            //
            // Sequence number states for a slot at position `pos`:
            //   seq == pos:     Slot is empty and ready for enqueue
            //   seq == pos + 1: Slot has data, ready for dequeue
            //   seq == pos + 2: Slot was consumed (relaxed ordering marker)
            //   seq < pos:      Slot is from a previous cycle (buffer full)
            let dif = Int64(bitPattern: seq) - Int64(bitPattern: pos)

            if dif == 0 {
                // Slot is ready for this position - try to claim it with CAS.
                // If another producer claimed it first, CAS fails and we retry.
                // Using weak CAS since we're in a retry loop - avoids redundant
                // retries on ARM's LL/SC spurious failures.
                let (exchanged, original) = enqueuePos.weakCompareExchange(
                    expected: pos,
                    desired: pos &+ 1,
                    successOrdering: .relaxed,
                    failureOrdering: .relaxed
                )

                if exchanged {
                    // We won the slot. Write the data, then update sequence
                    // with release ordering to make the write visible to consumer.
                    cell.pointee.data = element
                    cell.pointee.sequence.store(pos &+ 1, ordering: .releasing)
                    return
                }
                // CAS failed - another producer got this slot.
                // Use the value they wrote as our new starting point.
                pos = original
            } else if dif < 0 {
                // Sequence is behind position - this slot hasn't been recycled yet.
                // The buffer is full (consumer hasn't caught up). Spin-wait.
                pos = enqueuePos.load(ordering: .relaxed)
                continue
            } else {
                // dif > 0: Slot is already claimed by another producer who hasn't
                // finished writing yet. Reload enqueuePos to find a fresh slot.
                pos = enqueuePos.load(ordering: .relaxed)
            }
        }
    }

    /// Attempts to receive a message, scanning ahead for ready elements.
    ///
    /// Unlike strict FIFO, this may return elements out of order when
    /// the head slot isn't ready but later slots are.
    @inline(__always)
    public func tryRecv() -> sending Element? {
        let head = dequeuePos.load(ordering: .relaxed)
        let tail = enqueuePos.load(ordering: .acquiring)

        if head >= tail {
            return nil
        }

        // First, try to advance head over any already-consumed slots
        // This prevents the scan window from getting stuck
        advanceHead(from: head)
        let newHead = dequeuePos.load(ordering: .relaxed)

        // Scan from newHead, counting only non-consumed slots toward limit
        var pos = newHead
        var checked: Int = 0

        while pos < tail && checked < scanLimit {
            let index = Int(pos & mask)
            let cell = buffer.advanced(by: index)
            let seq = cell.pointee.sequence.load(ordering: .acquiring)

            if seq == pos &+ 1 {
                // Found ready slot - consume it
                let element = cell.pointee.data
                cell.pointee.data = nil

                // Mark as consumed (pos + 2) so we know to skip it
                cell.pointee.sequence.store(pos &+ 2, ordering: .releasing)

                // Try to advance head over consumed slots
                advanceHead(from: newHead)

                return element
            } else if seq == pos &+ 2 {
                // Already consumed - skip without counting toward limit
                pos &+= 1
                continue
            }

            // seq == pos means producer claimed but hasn't written yet
            // Count toward limit and keep scanning
            checked += 1
            pos &+= 1
        }

        return nil
    }

    /// Advances dequeuePos over consumed slots and recycles them.
    @inline(__always)
    private func advanceHead(from startHead: UInt64) {
        var pos = startHead

        while true {
            let index = Int(pos & mask)
            let cell = buffer.advanced(by: index)
            let seq = cell.pointee.sequence.load(ordering: .acquiring)

            if seq == pos &+ 2 {
                // This slot was consumed - recycle it for next cycle
                cell.pointee.sequence.store(pos &+ mask &+ 1, ordering: .releasing)
                pos &+= 1
            } else {
                break
            }
        }

        // Advance dequeuePos if we recycled any slots
        if pos > startHead {
            dequeuePos.store(pos, ordering: .releasing)
        }
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

extension RelaxedBoundedChannel: RelaxedQueue {}

extension RelaxedBoundedChannel: Sequence {
    public func makeIterator() -> RelaxedBoundedChannelIterator<Element> {
        RelaxedBoundedChannelIterator(channel: self)
    }
}

public struct RelaxedBoundedChannelIterator<Element: Sendable>: IteratorProtocol {
    let channel: RelaxedBoundedChannel<Element>

    public mutating func next() -> Element? {
        channel.recv()
    }
}
