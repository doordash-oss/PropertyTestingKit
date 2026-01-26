//
//  SPSCRing.swift
//  PropertyTestingKit
//
//  Bounded single-producer/single-consumer ring buffer.
//  Based on Rigtorp's SPSCQueue design with blocking when full.
//
//  Key properties:
//  - Pre-allocated buffer eliminates per-enqueue allocation overhead
//  - No atomic RMW (CAS) operations - just loads/stores with release/acquire
//  - Index caching reduces cross-cache-line reads
//  - Cache-line padding prevents false sharing between producer and consumer
//  - Blocks (spins) when full instead of dropping
//

import Atomics
import Foundation

/// Bounded single-producer/single-consumer ring buffer.
///
/// This queue is optimized for the case where one thread produces and another
/// consumes. Unlike `SPSCQueue`, this uses a fixed-size pre-allocated buffer
/// which eliminates allocation overhead during enqueue operations.
///
/// When the buffer is full, `enqueue` will spin-wait until space is available.
/// This provides back-pressure without dropping data.
///
/// - Warning: Using multiple producers or multiple consumers concurrently
///   will result in undefined behavior.
public final class SPSCRing<T: Sendable>: @unchecked Sendable {

    // ============================================================
    // BUFFER STORAGE
    // ============================================================

    /// Pre-allocated ring buffer storage.
    /// Using Optional<T> allows us to clear slots on dequeue.
    private let buffer: UnsafeMutablePointer<T?>

    /// Capacity mask for fast modulo (capacity must be power of 2).
    private let mask: Int

    /// Actual capacity of the buffer.
    public let capacity: Int

    // ============================================================
    // PRODUCER STATE (own cache line)
    // ============================================================

    /// Tail index atomic storage - where producer writes next.
    private let _tailPtr: UnsafeMutablePointer<UInt64.AtomicRepresentation>

    /// Cached copy of head to reduce cross-cache-line reads.
    /// Only accessed by producer.
    private var cachedHead: UInt64 = 0

    // Padding to separate producer and consumer cache lines
    private let _pad0: UnsafeMutablePointer<(Int64, Int64, Int64, Int64, Int64)>

    // ============================================================
    // CONSUMER STATE (own cache line)
    // ============================================================

    /// Head index atomic storage - where consumer reads next.
    private let _headPtr: UnsafeMutablePointer<UInt64.AtomicRepresentation>

    /// Cached copy of tail to reduce cross-cache-line reads.
    /// Only accessed by consumer.
    private var cachedTail: UInt64 = 0

    // Padding after consumer state
    private let _pad1: UnsafeMutablePointer<(Int64, Int64, Int64, Int64, Int64)>

    // ============================================================
    // CLOSE FLAG (separate cache line)
    // ============================================================

    /// Closed flag atomic storage.
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
    // INITIALIZATION
    // ============================================================

    /// Create a ring buffer with the specified capacity.
    ///
    /// - Parameter capacity: The maximum number of elements. Will be rounded
    ///   up to the next power of 2 for efficient indexing.
    public init(capacity: Int) {
        precondition(capacity > 0, "Capacity must be positive")

        // Round up to next power of 2
        let actualCapacity = capacity.nextPowerOf2()
        self.capacity = actualCapacity
        self.mask = actualCapacity - 1

        // Allocate and initialize buffer with nil
        self.buffer = .allocate(capacity: actualCapacity)
        buffer.initialize(repeating: nil, count: actualCapacity)

        // Allocate atomic storage
        _tailPtr = .allocate(capacity: 1)
        _tailPtr.initialize(to: UInt64.AtomicRepresentation(0))

        _headPtr = .allocate(capacity: 1)
        _headPtr.initialize(to: UInt64.AtomicRepresentation(0))

        _closedPtr = .allocate(capacity: 1)
        _closedPtr.initialize(to: Bool.AtomicRepresentation(false))

        // Allocate padding
        _pad0 = .allocate(capacity: 1)
        _pad0.initialize(to: (0, 0, 0, 0, 0))

        _pad1 = .allocate(capacity: 1)
        _pad1.initialize(to: (0, 0, 0, 0, 0))
    }

    deinit {
        // Clean up any remaining values
        let headVal = head.load(ordering: .relaxed)
        let tailVal = tail.load(ordering: .relaxed)

        var idx = headVal
        while idx != tailVal {
            let slot = Int(idx) & mask
            buffer[slot] = nil
            idx &+= 1
        }

        buffer.deinitialize(count: capacity)
        buffer.deallocate()

        // Deallocate atomic storage
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

    /// Enqueue a value, blocking if the buffer is full.
    ///
    /// This operation will spin-wait if the buffer is full until space becomes
    /// available. Only call from the single producer thread.
    ///
    /// - Parameter value: The value to enqueue.
    @inline(__always)
    public func enqueue(_ value: T) {
        let currentTail = tail.load(ordering: .relaxed)
        let nextTail = currentTail &+ 1

        // Fast path: check against cached head
        // Full when nextTail - head > capacity (i.e., would exceed capacity)
        if nextTail &- cachedHead <= UInt64(capacity) {
            // Space available, write value
            buffer[Int(currentTail) & mask] = value
            tail.store(nextTail, ordering: .releasing)
            return
        }

        // Slow path: refresh cached head and potentially wait
        enqueueSlowPath(value, currentTail: currentTail, nextTail: nextTail)
    }

    @inline(never)
    private func enqueueSlowPath(_ value: T, currentTail: UInt64, nextTail: UInt64) {
        // Refresh cached head
        cachedHead = head.load(ordering: .acquiring)

        // Spin until space is available
        // Full when nextTail - head > capacity
        while nextTail &- cachedHead > UInt64(capacity) {
            // Brief sleep to allow other threads to run
            // Using usleep instead of sched_yield because sched_yield doesn't
            // yield to Swift's cooperative async scheduler
            usleep(10)

            cachedHead = head.load(ordering: .acquiring)
        }

        // Space available, write value
        buffer[Int(currentTail) & mask] = value
        tail.store(nextTail, ordering: .releasing)
    }

    /// Enqueue a value asynchronously, yielding to Swift's cooperative scheduler if full.
    ///
    /// Use this variant when the consumer runs as a Swift Task on the same
    /// cooperative thread pool. The async yield ensures the consumer gets
    /// scheduled even when the producer is in a tight loop.
    ///
    /// - Parameter value: The value to enqueue.
    public func enqueueAsync(_ value: T) async {
        let currentTail = tail.load(ordering: .relaxed)
        let nextTail = currentTail &+ 1

        // Fast path: check against cached head
        if nextTail &- cachedHead <= UInt64(capacity) {
            buffer[Int(currentTail) & mask] = value
            tail.store(nextTail, ordering: .releasing)
            return
        }

        // Slow path: yield to async scheduler
        await enqueueAsyncSlowPath(value, currentTail: currentTail, nextTail: nextTail)
    }

    @inline(never)
    private func enqueueAsyncSlowPath(_ value: T, currentTail: UInt64, nextTail: UInt64) async {
        // Refresh cached head
        cachedHead = head.load(ordering: .acquiring)

        // Yield until space is available
        while nextTail &- cachedHead > UInt64(capacity) {
            // Yield to Swift's cooperative scheduler so consumer Task can run
            await Task.yield()
            cachedHead = head.load(ordering: .acquiring)
        }

        // Space available, write value
        buffer[Int(currentTail) & mask] = value
        tail.store(nextTail, ordering: .releasing)
    }

    /// Try to enqueue a value without blocking.
    ///
    /// - Parameter value: The value to enqueue.
    /// - Returns: `true` if the value was enqueued, `false` if the buffer is full.
    @inline(__always)
    public func tryEnqueue(_ value: T) -> Bool {
        let currentTail = tail.load(ordering: .relaxed)
        let nextTail = currentTail &+ 1

        // Check against cached head first
        // Full when nextTail - head > capacity
        if nextTail &- cachedHead > UInt64(capacity) {
            // Refresh cached head
            cachedHead = head.load(ordering: .acquiring)

            if nextTail &- cachedHead > UInt64(capacity) {
                return false  // Buffer is full
            }
        }

        // Space available, write value
        buffer[Int(currentTail) & mask] = value
        tail.store(nextTail, ordering: .releasing)
        return true
    }

    // ============================================================
    // CONSUMER OPERATIONS
    // ============================================================

    /// Dequeue a value. Only call from the single consumer thread.
    ///
    /// This operation is wait-free and returns immediately.
    ///
    /// - Returns: The dequeued value, or `nil` if the buffer is empty.
    @inline(__always)
    public func dequeue() -> T? {
        let currentHead = head.load(ordering: .relaxed)

        // Fast path: check against cached tail
        if currentHead == cachedTail {
            // Refresh cached tail
            cachedTail = tail.load(ordering: .acquiring)

            if currentHead == cachedTail {
                return nil  // Buffer is empty
            }
        }

        // Read the value
        let slot = Int(currentHead) & mask
        let value = buffer[slot]
        buffer[slot] = nil  // Clear the slot

        // Advance head
        head.store(currentHead &+ 1, ordering: .releasing)

        return value
    }

    /// Whether the buffer is empty.
    ///
    /// - Note: This is only accurate when called from the consumer thread.
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

    /// Close the buffer. After closing, no more values should be enqueued.
    @inline(__always)
    public func close() {
        closed.store(true, ordering: .releasing)
    }

    /// Whether the buffer has been closed.
    @inline(__always)
    public var isClosed: Bool {
        closed.load(ordering: .acquiring)
    }

    /// Receive a value, returning `nil` if the buffer is empty.
    ///
    /// This is an alias for `dequeue()` to match channel semantics.
    @inline(__always)
    public func receive() -> T? {
        dequeue()
    }
}

// Note: nextPowerOf2() extension is defined in Channel.swift
