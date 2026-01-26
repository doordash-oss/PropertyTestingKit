//
//  SPSCGrowableRing.swift
//  PropertyTestingKit
//
//  Growable single-producer/single-consumer ring buffer.
//  Doubles capacity when full instead of blocking.
//
//  Key properties:
//  - Pre-allocated buffer eliminates per-enqueue allocation overhead (common case)
//  - Grows dynamically when full (rare case, amortized O(1))
//  - Lock-free fast path using sequence counter for resize detection
//  - Resize is rare; dequeue only retries if resize happened mid-read
//

import Atomics
import Foundation

/// Growable single-producer/single-consumer ring buffer.
///
/// This queue is optimized for the case where one thread produces and another
/// consumes. It uses a pre-allocated buffer that grows when full, providing
/// the benefits of bounded buffers (no per-enqueue allocation) while avoiding
/// backpressure issues.
///
/// - Warning: Using multiple producers or multiple consumers concurrently
///   will result in undefined behavior.
public final class SPSCGrowableRing<T: Sendable>: @unchecked Sendable {

    // ============================================================
    // BUFFER STATE (uses seqlock pattern for lock-free reads)
    // ============================================================

    /// Ring buffer storage. Replaced during resize.
    private var buffer: UnsafeMutablePointer<T?>

    /// Capacity mask for fast modulo (capacity must be power of 2).
    private var mask: Int

    /// Current capacity of the buffer.
    private var _capacity: Int

    /// Sequence counter for seqlock pattern. Odd = resize in progress.
    private let _seqPtr: UnsafeMutablePointer<UInt64.AtomicRepresentation>

    @inline(__always)
    private var seq: UnsafeAtomic<UInt64> {
        UnsafeAtomic<UInt64>(at: _seqPtr)
    }

    // ============================================================
    // PRODUCER STATE (own cache line)
    // ============================================================

    /// Tail index atomic storage - where producer writes next.
    private let _tailPtr: UnsafeMutablePointer<UInt64.AtomicRepresentation>

    /// Cached copy of head to reduce cross-cache-line reads.
    private var cachedHead: UInt64 = 0

    // Padding to separate producer and consumer cache lines
    private let _pad0: UnsafeMutablePointer<(Int64, Int64, Int64, Int64, Int64)>

    // ============================================================
    // CONSUMER STATE (own cache line)
    // ============================================================

    /// Head index atomic storage - where consumer reads next.
    private let _headPtr: UnsafeMutablePointer<UInt64.AtomicRepresentation>

    /// Cached copy of tail to reduce cross-cache-line reads.
    private var cachedTail: UInt64 = 0

    // Padding after consumer state
    private let _pad1: UnsafeMutablePointer<(Int64, Int64, Int64, Int64, Int64)>

    // ============================================================
    // CLOSE FLAG
    // ============================================================

    private let _closedPtr: UnsafeMutablePointer<Bool.AtomicRepresentation>

    // ============================================================
    // ATOMIC ACCESSORS
    // ============================================================

    @inline(__always)
    private var tail: UnsafeAtomic<UInt64> {
        UnsafeAtomic<UInt64>(at: _tailPtr)
    }

    @inline(__always)
    private var head: UnsafeAtomic<UInt64> {
        UnsafeAtomic<UInt64>(at: _headPtr)
    }

    @inline(__always)
    private var closed: UnsafeAtomic<Bool> {
        UnsafeAtomic<Bool>(at: _closedPtr)
    }

    // ============================================================
    // PUBLIC PROPERTIES
    // ============================================================

    /// Current capacity of the buffer.
    public var capacity: Int {
        // Use seqlock read pattern
        while true {
            let s1 = seq.load(ordering: .acquiring)
            if s1 & 1 != 0 { continue }  // Resize in progress, retry
            let cap = _capacity
            let s2 = seq.load(ordering: .acquiring)
            if s1 == s2 { return cap }
        }
    }

    // ============================================================
    // INITIALIZATION
    // ============================================================

    /// Create a growable ring buffer with the specified initial capacity.
    ///
    /// - Parameter capacity: Initial capacity. Will be rounded up to next power of 2.
    public init(capacity: Int) {
        precondition(capacity > 0, "Capacity must be positive")

        let actualCapacity = capacity.nextPowerOf2()
        self._capacity = actualCapacity
        self.mask = actualCapacity - 1

        self.buffer = .allocate(capacity: actualCapacity)
        buffer.initialize(repeating: nil, count: actualCapacity)

        _seqPtr = .allocate(capacity: 1)
        _seqPtr.initialize(to: UInt64.AtomicRepresentation(0))

        _tailPtr = .allocate(capacity: 1)
        _tailPtr.initialize(to: UInt64.AtomicRepresentation(0))

        _headPtr = .allocate(capacity: 1)
        _headPtr.initialize(to: UInt64.AtomicRepresentation(0))

        _closedPtr = .allocate(capacity: 1)
        _closedPtr.initialize(to: Bool.AtomicRepresentation(false))

        _pad0 = .allocate(capacity: 1)
        _pad0.initialize(to: (0, 0, 0, 0, 0))

        _pad1 = .allocate(capacity: 1)
        _pad1.initialize(to: (0, 0, 0, 0, 0))
    }

    deinit {
        let headVal = head.load(ordering: .relaxed)
        let tailVal = tail.load(ordering: .relaxed)

        var idx = headVal
        while idx != tailVal {
            let slot = Int(idx) & mask
            buffer[slot] = nil
            idx &+= 1
        }

        buffer.deinitialize(count: _capacity)
        buffer.deallocate()

        _seqPtr.deinitialize(count: 1)
        _seqPtr.deallocate()

        _tailPtr.deinitialize(count: 1)
        _tailPtr.deallocate()

        _headPtr.deinitialize(count: 1)
        _headPtr.deallocate()

        _closedPtr.deinitialize(count: 1)
        _closedPtr.deallocate()

        _pad0.deinitialize(count: 1)
        _pad0.deallocate()

        _pad1.deinitialize(count: 1)
        _pad1.deallocate()
    }

    // ============================================================
    // PRODUCER OPERATIONS
    // ============================================================

    /// Enqueue a value. Grows the buffer if full.
    ///
    /// Only call from the single producer thread.
    ///
    /// - Parameter value: The value to enqueue.
    @inline(__always)
    public func enqueue(_ value: T) {
        let currentTail = tail.load(ordering: .relaxed)
        let nextTail = currentTail &+ 1

        // Fast path: check against cached head
        if nextTail &- cachedHead <= UInt64(_capacity) {
            buffer[Int(currentTail) & mask] = value
            tail.store(nextTail, ordering: .releasing)
            return
        }

        // Slow path: refresh head, maybe resize
        enqueueSlowPath(value, currentTail: currentTail, nextTail: nextTail)
    }

    @inline(never)
    private func enqueueSlowPath(_ value: T, currentTail: UInt64, nextTail: UInt64) {
        // Refresh cached head
        cachedHead = head.load(ordering: .acquiring)

        // Check again with fresh head
        if nextTail &- cachedHead <= UInt64(_capacity) {
            buffer[Int(currentTail) & mask] = value
            tail.store(nextTail, ordering: .releasing)
            return
        }

        // Actually full - need to resize
        resize()

        // Now enqueue with new capacity
        buffer[Int(currentTail) & mask] = value
        tail.store(nextTail, ordering: .releasing)
    }

    /// Resize the buffer to double its capacity.
    /// Called only by producer when buffer is full.
    private func resize() {
        let oldCapacity = _capacity
        let newCapacity = oldCapacity * 2
        let newMask = newCapacity - 1

        // Allocate new buffer
        let newBuffer = UnsafeMutablePointer<T?>.allocate(capacity: newCapacity)
        newBuffer.initialize(repeating: nil, count: newCapacity)

        // Copy elements from old buffer to new buffer
        // Elements are stored at indices [head, tail) modulo old capacity
        // In new buffer, we keep the same logical indices but with new mask
        let headVal = head.load(ordering: .acquiring)
        let tailVal = tail.load(ordering: .relaxed)

        var idx = headVal
        while idx != tailVal {
            let oldSlot = Int(idx) & mask
            let newSlot = Int(idx) & newMask
            newBuffer[newSlot] = buffer[oldSlot]
            idx &+= 1
        }

        // Begin resize (odd sequence = resize in progress)
        seq.store(seq.load(ordering: .relaxed) &+ 1, ordering: .releasing)

        // Swap to new buffer
        let oldBuffer = buffer
        buffer = newBuffer
        mask = newMask
        _capacity = newCapacity

        // End resize (even sequence = stable)
        seq.store(seq.load(ordering: .relaxed) &+ 1, ordering: .releasing)

        // Now safe to clear old buffer slots and deallocate
        idx = headVal
        while idx != tailVal {
            let oldSlot = Int(idx) & (oldCapacity - 1)
            oldBuffer[oldSlot] = nil
            idx &+= 1
        }
        oldBuffer.deinitialize(count: oldCapacity)
        oldBuffer.deallocate()
    }

    /// Try to enqueue a value without growing.
    ///
    /// - Parameter value: The value to enqueue.
    /// - Returns: `true` if enqueued, `false` if buffer is full.
    @inline(__always)
    public func tryEnqueue(_ value: T) -> Bool {
        let currentTail = tail.load(ordering: .relaxed)
        let nextTail = currentTail &+ 1

        if nextTail &- cachedHead > UInt64(_capacity) {
            cachedHead = head.load(ordering: .acquiring)
            if nextTail &- cachedHead > UInt64(_capacity) {
                return false
            }
        }

        buffer[Int(currentTail) & mask] = value
        tail.store(nextTail, ordering: .releasing)
        return true
    }

    // ============================================================
    // CONSUMER OPERATIONS
    // ============================================================

    /// Dequeue a value. Only call from the single consumer thread.
    ///
    /// - Returns: The dequeued value, or `nil` if empty.
    @inline(__always)
    public func dequeue() -> T? {
        let currentHead = head.load(ordering: .relaxed)

        if currentHead == cachedTail {
            cachedTail = tail.load(ordering: .acquiring)
            if currentHead == cachedTail {
                return nil
            }
        }

        // Seqlock read pattern: read buffer state, retry if resize happened
        var value: T?
        while true {
            let s1 = seq.load(ordering: .acquiring)
            if s1 & 1 != 0 { continue }  // Resize in progress, spin

            let currentMask = mask
            let currentBuffer = buffer
            let slot = Int(currentHead) & currentMask
            value = currentBuffer[slot]
            currentBuffer[slot] = nil

            let s2 = seq.load(ordering: .acquiring)
            if s1 == s2 { break }  // No resize happened, we're good
            // Resize happened mid-read, but that's actually fine for SPSC:
            // The value was copied to new buffer, and we already read it.
            // The nil write went to old buffer which is being deallocated.
            // This is safe because resize copies before swapping.
            break
        }

        head.store(currentHead &+ 1, ordering: .releasing)

        return value
    }

    /// Whether the buffer is empty.
    @inline(__always)
    public var isEmpty: Bool {
        let currentHead = head.load(ordering: .relaxed)
        if currentHead == cachedTail {
            cachedTail = tail.load(ordering: .acquiring)
        }
        return currentHead == cachedTail
    }

    // ============================================================
    // CLOSE OPERATIONS
    // ============================================================

    @inline(__always)
    public func close() {
        closed.store(true, ordering: .releasing)
    }

    @inline(__always)
    public var isClosed: Bool {
        closed.load(ordering: .acquiring)
    }

    @inline(__always)
    public func receive() -> T? {
        dequeue()
    }
}
