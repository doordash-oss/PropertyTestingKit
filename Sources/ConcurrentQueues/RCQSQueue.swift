//
//  RCQSQueue.swift
//  PropertyTestingKit
//
//  Relaxed Concurrent Queue Single (RCQS) - EXACT implementation from paper.
//
//  ## Algorithm (from paper, RCQS variant)
//
//  Uses single CAS by packing state into LSB of data pointer:
//  - FREE = 0 (LSB = 0)
//  - OCCUPIED = pointer | 1 (LSB = 1)
//
//  ENQUEUE(x):
//    i = FAA(&tail, 1)
//    while true:
//      c = cells[i % n]
//      s = c.load()
//      if s.state == FREE:
//        if CAS(&c, s, (x, OCCUPIED)):
//          return
//
//  DEQUEUE():
//    i = FAA(&head, 1)
//    while true:
//      c = cells[i % n]
//      s = c.load()
//      if s.state == OCCUPIED:
//        if CAS(&c, s, (null, FREE)):
//          return s.data
//
//  ## Reference
//
//  Based on: "A Family of Relaxed Concurrent Queues for Low-Latency Operations"
//  https://dl.acm.org/doi/10.1145/3565514
//

import Atomics
import Foundation

/// A relaxed queue using single CAS with packed state bit.
/// This is the EXACT algorithm from the paper - no modifications.
public final class RCQSQueue<Element: Sendable>: @unchecked Sendable, RelaxedQueue {

    // Each cell stores a packed value: (pointer to boxed element) | state_bit
    // LSB = 0: FREE (cell available for producer)
    // LSB = 1: OCCUPIED (cell has data for consumer)
    private let cells: UnsafeMutablePointer<ManagedAtomic<UInt>>
    private let n: Int      // buffer size
    private let mask: Int   // n - 1, for fast modulo

    private let tail: ManagedAtomic<UInt64>  // enqueue position
    private let head: ManagedAtomic<UInt64>  // dequeue position

    private let _closed: ManagedAtomic<Bool>

    public var isClosed: Bool {
        _closed.load(ordering: .acquiring)
    }

    /// Creates an RCQS queue.
    ///
    /// - Parameters:
    ///   - capacity: Buffer capacity (rounded to power of 2). Default 1024.
    public init(capacity: Int = 1024) {
        let actualCapacity = capacity.nextPowerOf2()
        self.n = actualCapacity
        self.mask = actualCapacity - 1

        self.cells = .allocate(capacity: actualCapacity)
        for idx in 0..<actualCapacity {
            // Initialize all cells to FREE (0)
            cells.advanced(by: idx).initialize(to: ManagedAtomic(0))
        }

        self.tail = ManagedAtomic(0)
        self.head = ManagedAtomic(0)
        self._closed = ManagedAtomic(false)
    }

    deinit {
        // Clean up any remaining boxed elements
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .relaxed)

        if h < t {
            for idx in h..<t {
                let cellIdx = Int(idx) & mask
                let packed = cells.advanced(by: cellIdx).pointee.load(ordering: .relaxed)
                if (packed & 1) == 1 {
                    let ptr = packed & ~1
                    if ptr != 0 {
                        let boxed = Unmanaged<Box<Element>>.fromOpaque(UnsafeRawPointer(bitPattern: ptr)!)
                        boxed.release()
                    }
                }
            }
        }

        cells.deinitialize(count: n)
        cells.deallocate()
    }

    /// Box class to heap-allocate elements for pointer storage
    private final class Box<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) {
            self.value = value
        }
    }

    /// Pack a boxed element pointer with OCCUPIED state (LSB = 1)
    @inline(__always)
    private func pack(_ x: Element) -> UInt {
        let boxed = Box(x)
        let unmanaged = Unmanaged.passRetained(boxed)
        let ptr = UInt(bitPattern: unmanaged.toOpaque())
        return ptr | 1  // Set LSB = OCCUPIED
    }

    /// Unpack pointer and extract element, releasing the box
    @inline(__always)
    private func unpack(_ packed: UInt) -> Element {
        let ptr = packed & ~1  // Clear LSB to get pointer
        let unmanaged = Unmanaged<Box<Element>>.fromOpaque(UnsafeRawPointer(bitPattern: ptr)!)
        let box = unmanaged.takeRetainedValue()
        return box.value
    }

    // MARK: - Paper's RCQS Algorithm (exact)

    /// ENQUEUE(x) - exact paper algorithm
    ///
    /// i = FAA(&tail, 1)
    /// while true:
    ///   c = cells[i % n]
    ///   s = c.load()
    ///   if s.state == FREE:
    ///     if CAS(&c, s, (x, OCCUPIED)):
    ///       return
    @inline(__always)
    public func send(_ x: consuming Element) {
        // Pack element first
        let packed = pack(x)

        // i = FAA(&tail, 1)
        let i = tail.loadThenWrappingIncrement(ordering: .relaxed)
        let c = cells.advanced(by: Int(i) & mask)

        // while true
        while true {
            // s = c.load()
            let s = c.pointee.load(ordering: .acquiring)

            // if s.state == FREE
            if (s & 1) == 0 {
                // CAS(&c, s, (x, OCCUPIED))
                let (success, _) = c.pointee.weakCompareExchange(
                    expected: s,
                    desired: packed,
                    successOrdering: .releasing,
                    failureOrdering: .relaxed
                )
                if success {
                    return
                }
            }
            // spin
        }
    }

    /// DEQUEUE() - exact paper algorithm
    ///
    /// i = FAA(&head, 1)
    /// while true:
    ///   c = cells[i % n]
    ///   s = c.load()
    ///   if s.state == OCCUPIED:
    ///     if CAS(&c, s, (null, FREE)):
    ///       return s.data
    @inline(__always)
    public func recv() -> sending Element? {
        // i = FAA(&head, 1)
        let i = head.loadThenWrappingIncrement(ordering: .relaxed)
        let c = cells.advanced(by: Int(i) & mask)

        // while true
        while true {
            // s = c.load()
            let s = c.pointee.load(ordering: .acquiring)

            // if s.state == OCCUPIED
            if (s & 1) == 1 {
                // CAS(&c, s, (null, FREE))
                let (success, _) = c.pointee.weakCompareExchange(
                    expected: s,
                    desired: 0,
                    successOrdering: .acquiring,
                    failureOrdering: .relaxed
                )
                if success {
                    // return s.data
                    return unpack(s)
                }
            }
            // spin
        }
    }

    // MARK: - Extensions (not in paper)

    /// Non-blocking receive - checks if data available first
    @inline(__always)
    public func tryRecv() -> sending Element? {
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)

        if h >= t {
            return nil
        }

        return recv()
    }

    public func close() {
        _closed.store(true, ordering: .releasing)
    }
}

// MARK: - Sequence Conformance

extension RCQSQueue: Sequence {
    public func makeIterator() -> RCQSQueueIterator<Element> {
        RCQSQueueIterator(queue: self)
    }
}

public struct RCQSQueueIterator<Element: Sendable>: IteratorProtocol {
    let queue: RCQSQueue<Element>

    public mutating func next() -> Element? {
        queue.recv()
    }
}
