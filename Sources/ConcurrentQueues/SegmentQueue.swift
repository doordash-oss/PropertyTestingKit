//
//  SegmentQueue.swift
//  PropertyTestingKit
//
//  A segment-based relaxed queue following the literature's approach.
//
//  ## Algorithm
//
//  The buffer is divided into fixed-size segments. Within a segment,
//  elements can be accessed in any order. Across segments, FIFO is preserved.
//
//  Segment states:
//  - Operations within the current head segment scan for ready slots
//  - When head segment is empty, advance to next segment
//  - Tail segment receives new enqueues
//
//  This provides configurable relaxation: larger segments = more relaxation.
//
//  ## Reference
//
//  Based on: "Distributed queues in shared memory" and segment-based relaxation
//  approaches described in concurrent queue literature.
//

import Atomics
import Foundation

/// A segment-based relaxed queue with configurable segment size.
///
/// Elements within a segment may be delivered out of order, but segments
/// themselves are processed in FIFO order. Segment size controls the
/// relaxation/ordering trade-off.
public final class SegmentQueue<Element: Sendable>: @unchecked Sendable, RelaxedQueue {

    private struct Slot {
        var sequence: ManagedAtomic<UInt64>
        var data: Element?

        init(sequence: UInt64) {
            self.sequence = ManagedAtomic(sequence)
            self.data = nil
        }
    }

    private let buffer: UnsafeMutablePointer<Slot>
    private let capacity: Int
    private let mask: UInt64

    /// Size of each segment - controls relaxation level
    public let segmentSize: Int

    private let enqueuePos: ManagedAtomic<UInt64>
    private let dequeuePos: ManagedAtomic<UInt64>

    /// Tracks the current head segment for efficient scanning
    private let headSegment: ManagedAtomic<UInt64>

    private let _closed: ManagedAtomic<Bool>

    public var isClosed: Bool {
        _closed.load(ordering: .acquiring)
    }

    /// Creates a segment-based queue.
    ///
    /// - Parameters:
    ///   - segmentSize: Number of slots per segment. Controls relaxation.
    ///                  segmentSize=1 approximates strict FIFO.
    ///                  Larger values = more relaxation, better throughput.
    ///   - capacity: Total buffer capacity (rounded to power of 2).
    public init(segmentSize: Int = 16, capacity: Int = 1024) {
        precondition(segmentSize >= 1, "Segment size must be at least 1")

        self.segmentSize = segmentSize

        let actualCapacity = capacity.nextPowerOf2()
        self.capacity = actualCapacity
        self.mask = UInt64(actualCapacity - 1)

        self.buffer = .allocate(capacity: actualCapacity)
        for i in 0..<actualCapacity {
            buffer.advanced(by: i).initialize(to: Slot(sequence: UInt64(i)))
        }

        self.enqueuePos = ManagedAtomic(0)
        self.dequeuePos = ManagedAtomic(0)
        self.headSegment = ManagedAtomic(0)
        self._closed = ManagedAtomic(false)
    }

    deinit {
        buffer.deinitialize(count: capacity)
        buffer.deallocate()
    }

    /// Calculates the segment index for a given position
    @inline(__always)
    private func segmentIndex(for pos: UInt64) -> UInt64 {
        pos / UInt64(segmentSize)
    }

    /// Calculates the start position of a segment
    @inline(__always)
    private func segmentStart(_ segmentIdx: UInt64) -> UInt64 {
        segmentIdx * UInt64(segmentSize)
    }

    @inline(__always)
    public func send(_ element: consuming Element) {
        var pos = enqueuePos.load(ordering: .relaxed)

        while true {
            let index = Int(pos & mask)
            let slot = buffer.advanced(by: index)
            let seq = slot.pointee.sequence.load(ordering: .acquiring)

            let dif = Int64(bitPattern: seq) - Int64(bitPattern: pos)

            if dif == 0 {
                // Slot ready for this position
                let (exchanged, original) = enqueuePos.weakCompareExchange(
                    expected: pos,
                    desired: pos &+ 1,
                    successOrdering: .relaxed,
                    failureOrdering: .relaxed
                )

                if exchanged {
                    slot.pointee.data = element
                    slot.pointee.sequence.store(pos &+ 1, ordering: .releasing)
                    return
                }
                pos = original
            } else if dif < 0 {
                // Buffer full - spin wait for space
                pos = enqueuePos.load(ordering: .relaxed)
            } else {
                pos = enqueuePos.load(ordering: .relaxed)
            }
        }
    }

    @inline(__always)
    public func tryRecv() -> sending Element? {
        let currentHeadSeg = headSegment.load(ordering: .relaxed)
        let tail = enqueuePos.load(ordering: .acquiring)

        let segStart = segmentStart(currentHeadSeg)

        if segStart >= tail {
            return nil // Queue empty
        }

        // Calculate segment boundaries
        let segEnd = Swift.min(segStart + UInt64(segmentSize), tail)

        // Scan the current head segment for any ready slot
        for pos in segStart..<segEnd {
            let index = Int(pos & mask)
            let slot = buffer.advanced(by: index)
            let seq = slot.pointee.sequence.load(ordering: AtomicLoadOrdering.acquiring)

            // seq == pos + 1 means slot has data
            if seq == pos &+ 1 {
                // Try to consume: mark as pos + 2
                let (claimed, _) = slot.pointee.sequence.weakCompareExchange(
                    expected: pos &+ 1,
                    desired: pos &+ 2,
                    successOrdering: AtomicUpdateOrdering.acquiring,
                    failureOrdering: AtomicLoadOrdering.relaxed
                )

                if claimed {
                    let element = slot.pointee.data
                    slot.pointee.data = nil

                    // Recycle slot for next cycle
                    slot.pointee.sequence.store(pos &+ mask &+ 1, ordering: AtomicStoreOrdering.releasing)

                    // Update dequeuePos if this was at head
                    advanceDequeuePos()

                    // Check if we should advance to next segment
                    maybeAdvanceSegment(currentHeadSeg, tail: tail)

                    return element
                }
                // Someone else got it, continue scanning
            }
        }

        // Segment might be fully consumed - try to advance
        maybeAdvanceSegment(currentHeadSeg, tail: tail)
        return nil
    }

    /// Advances dequeuePos past consumed slots
    private func advanceDequeuePos() {
        var pos = dequeuePos.load(ordering: AtomicLoadOrdering.relaxed)

        while true {
            let index = Int(pos & mask)
            let slot = buffer.advanced(by: index)
            let seq = slot.pointee.sequence.load(ordering: AtomicLoadOrdering.acquiring)

            // Check if recycled (ready for next cycle)
            let expectedRecycled = pos &+ mask &+ 1
            if seq == expectedRecycled || seq == pos &+ 2 {
                let (advanced, current) = dequeuePos.weakCompareExchange(
                    expected: pos,
                    desired: pos &+ 1,
                    successOrdering: AtomicUpdateOrdering.relaxed,
                    failureOrdering: AtomicLoadOrdering.relaxed
                )

                if advanced {
                    // If we consumed at pos + 2, recycle it
                    if seq == pos &+ 2 {
                        slot.pointee.sequence.store(pos &+ mask &+ 1, ordering: AtomicStoreOrdering.releasing)
                    }
                    pos = pos &+ 1
                } else {
                    pos = current
                }
            } else {
                break
            }
        }
    }

    /// Checks if the current head segment is empty and advances if so
    private func maybeAdvanceSegment(_ currentSeg: UInt64, tail: UInt64) {
        let segStart = segmentStart(currentSeg)
        let segEnd = segStart + UInt64(segmentSize)

        // Check if all slots in segment are consumed/recycled
        var allConsumed = true
        for pos in segStart..<Swift.min(segEnd, tail) {
            let index = Int(pos & mask)
            let slot = buffer.advanced(by: index)
            let seq = slot.pointee.sequence.load(ordering: AtomicLoadOrdering.relaxed)

            let expectedRecycled = pos &+ mask &+ 1
            if seq != expectedRecycled && seq != pos &+ 2 {
                allConsumed = false
                break
            }
        }

        if allConsumed && segEnd <= tail {
            // Try to advance to next segment
            _ = headSegment.weakCompareExchange(
                expected: currentSeg,
                desired: currentSeg + 1,
                successOrdering: .relaxed,
                failureOrdering: .relaxed
            )
        }
    }

    @inline(__always)
    public func recv() -> sending Element? {
        while true {
            if let element = tryRecv() {
                return element
            }

            if _closed.load(ordering: .acquiring) {
                // Queue is closed. Check if truly empty.
                let currentHeadSeg = headSegment.load(ordering: .acquiring)
                let tail = enqueuePos.load(ordering: .acquiring)
                let segStart = segmentStart(currentHeadSeg)
                if segStart >= tail {
                    return nil
                }
                // head < tail but tryRecv() returned nil means all slots in
                // the current segment are consumed. Force advance to next segment.
                forceAdvanceSegment(currentSeg: currentHeadSeg, tail: tail)
            }
        }
    }

    /// When draining a closed queue, force advance to the next segment
    /// if the current segment is fully consumed.
    private func forceAdvanceSegment(currentSeg: UInt64, tail: UInt64) {
        let segStart = segmentStart(currentSeg)
        let segEnd = segStart + UInt64(segmentSize)

        // Check if all slots in current segment up to tail are consumed
        var allConsumed = true
        for pos in segStart..<Swift.min(segEnd, tail) {
            let index = Int(pos & mask)
            let slot = buffer.advanced(by: index)
            let seq = slot.pointee.sequence.load(ordering: .acquiring)

            // If seq == pos + 1, slot has data (not consumed)
            if seq == pos &+ 1 {
                allConsumed = false
                break
            }
        }

        if allConsumed && segEnd <= tail {
            // All slots consumed, try to advance to next segment
            _ = headSegment.weakCompareExchange(
                expected: currentSeg,
                desired: currentSeg + 1,
                successOrdering: .relaxed,
                failureOrdering: .relaxed
            )
        }
    }

    public func close() {
        _closed.store(true, ordering: .releasing)
    }
}

// MARK: - Sequence Conformance

extension SegmentQueue: Sequence {
    public func makeIterator() -> SegmentQueueIterator<Element> {
        SegmentQueueIterator(queue: self)
    }
}

public struct SegmentQueueIterator<Element: Sendable>: IteratorProtocol {
    let queue: SegmentQueue<Element>

    public mutating func next() -> Element? {
        queue.recv()
    }
}
