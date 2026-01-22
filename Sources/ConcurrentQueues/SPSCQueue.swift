//
//  SPSCQueue.swift
//  PropertyTestingKit
//
//  Unbounded single-producer/single-consumer queue based on Vyukov's algorithm.
//  https://www.1024cores.net/home/lock-free-algorithms/queues/unbounded-spsc-queue
//
//  Key properties:
//  - No atomic RMW (CAS) operations - just loads/stores with release/acquire
//  - Wait-free dequeue (always completes in bounded steps)
//  - Wait-free enqueue in common case (only allocates when node cache empty)
//  - Cache-conscious layout prevents false sharing between producer and consumer
//

import Atomics
import Foundation

/// Unbounded single-producer/single-consumer queue.
///
/// This queue is optimized for the case where one thread produces and another
/// consumes. It achieves high throughput by:
/// - Using only release/acquire memory ordering (no CAS)
/// - Caching consumed nodes for reuse (reduces allocations)
/// - Separating producer and consumer data onto different cache lines
///
/// - Warning: Using multiple producers or multiple consumers concurrently
///   will result in undefined behavior.
public final class SPSCQueue<T: Sendable>: @unchecked Sendable {

    /// Internal node structure.
    /// The `next` field uses atomic storage for cross-thread visibility.
    private struct Node {
        var next: UInt.AtomicRepresentation
        var value: T?

        init() {
            self.next = UInt.AtomicRepresentation(0)
            self.value = nil
        }
    }

    // ============================================================
    // CONSUMER PART - accessed mainly by consumer, rarely by producer
    // ============================================================

    /// Tail of the queue (consumer reads from here).
    private let _tailPtr: UnsafeMutablePointer<UInt.AtomicRepresentation>

    /// Closed flag
    private let _closedPtr: UnsafeMutablePointer<Bool.AtomicRepresentation>

    // Padding to separate consumer and producer cache lines (64 bytes)
    private let _pad1: UnsafeMutablePointer<(Int64, Int64, Int64, Int64, Int64, Int64)>

    // ============================================================
    // PRODUCER PART - accessed only by producer
    // ============================================================

    /// Head of the queue (producer writes here).
    private var head: UnsafeMutablePointer<Node>

    /// First unused node (tail of node cache).
    private var first: UnsafeMutablePointer<Node>

    /// Cached copy of tail to reduce cache line traffic.
    private var tailCopy: UnsafeMutablePointer<Node>

    // ============================================================
    // COMPUTED ATOMIC ACCESSORS
    // ============================================================

    @inline(__always)
    private var tail: UnsafeAtomic<UInt> {
        UnsafeAtomic<UInt>(at: _tailPtr)
    }

    @inline(__always)
    private var closed: UnsafeAtomic<Bool> {
        UnsafeAtomic<Bool>(at: _closedPtr)
    }

    @inline(__always)
    private static func next(of node: UnsafeMutablePointer<Node>) -> UnsafeAtomic<UInt> {
        // Get pointer to the `next` field within the Node
        let nextPtr = UnsafeMutableRawPointer(node)
            .assumingMemoryBound(to: UInt.AtomicRepresentation.self)
        return UnsafeAtomic<UInt>(at: nextPtr)
    }

    // ============================================================
    // INITIALIZATION
    // ============================================================

    public init() {
        // Allocate atomic storage
        _tailPtr = .allocate(capacity: 1)
        _closedPtr = .allocate(capacity: 1)
        _pad1 = .allocate(capacity: 1)

        // Allocate initial sentinel node
        let n = UnsafeMutablePointer<Node>.allocate(capacity: 1)
        n.initialize(to: Node())

        // Initialize atomic storage
        _tailPtr.initialize(to: UInt.AtomicRepresentation(UInt(bitPattern: n)))
        _closedPtr.initialize(to: Bool.AtomicRepresentation(false))
        _pad1.initialize(to: (0, 0, 0, 0, 0, 0))

        // All pointers start at the sentinel
        self.head = n
        self.first = n
        self.tailCopy = n
    }

    deinit {
        // Walk from first (oldest cached node) to end and deallocate all
        var current = first
        while true {
            let nextVal = Self.next(of: current).load(ordering: .relaxed)
            current.pointee.value = nil  // Release any stored value
            current.deinitialize(count: 1)
            current.deallocate()

            if nextVal == 0 {
                break
            }
            current = UnsafeMutablePointer<Node>(bitPattern: nextVal)!
        }

        // Deallocate atomic storage
        _tailPtr.deinitialize(count: 1)
        _tailPtr.deallocate()
        _closedPtr.deinitialize(count: 1)
        _closedPtr.deallocate()
        _pad1.deinitialize(count: 1)
        _pad1.deallocate()
    }

    // ============================================================
    // PRODUCER OPERATIONS
    // ============================================================

    /// Enqueue a value. Only call from the single producer thread.
    ///
    /// This operation is wait-free in the common case. It only allocates
    /// memory when the internal node cache is exhausted.
    ///
    /// - Parameter value: The value to enqueue.
    public func enqueue(_ value: T) {
        // Get a node from cache or allocate new
        let n = allocNode()

        // Prepare the node
        Self.next(of: n).store(0, ordering: .relaxed)
        n.pointee.value = value

        // Publish to consumer: store with release ordering
        // This ensures the value write is visible before the pointer
        Self.next(of: head).store(UInt(bitPattern: n), ordering: .releasing)

        // Advance head (producer-local, no ordering needed)
        head = n
    }

    /// Allocate a node from the cache, or create a new one if cache is empty.
    private func allocNode() -> UnsafeMutablePointer<Node> {
        // Fast path: try to get from cache without reading tail
        if first != tailCopy {
            let n = first
            let nextVal = Self.next(of: n).load(ordering: .relaxed)
            first = UnsafeMutablePointer<Node>(bitPattern: nextVal)!
            return n
        }

        // Refresh tailCopy from actual tail (requires reading consumer's cache line)
        tailCopy = UnsafeMutablePointer<Node>(bitPattern:
            tail.load(ordering: .acquiring))!

        // Try again with fresh tail position
        if first != tailCopy {
            let n = first
            let nextVal = Self.next(of: n).load(ordering: .relaxed)
            first = UnsafeMutablePointer<Node>(bitPattern: nextVal)!
            return n
        }

        // Cache is truly empty, allocate new node
        let n = UnsafeMutablePointer<Node>.allocate(capacity: 1)
        n.initialize(to: Node())
        return n
    }

    // ============================================================
    // CONSUMER OPERATIONS
    // ============================================================

    /// Dequeue a value. Only call from the single consumer thread.
    ///
    /// This operation is always wait-free.
    ///
    /// - Returns: The dequeued value, or `nil` if the queue is empty.
    public func dequeue() -> T? {
        // Load tail locally
        let tailVal = tail.load(ordering: .relaxed)
        let tailPtr = UnsafeMutablePointer<Node>(bitPattern: tailVal)!

        // Check if there's a next node (acquire ordering to see producer's writes)
        let nextVal = Self.next(of: tailPtr).load(ordering: .acquiring)

        guard nextVal != 0 else {
            return nil  // Queue is empty
        }

        let nextPtr = UnsafeMutablePointer<Node>(bitPattern: nextVal)!

        // Read the value before advancing tail
        let value = nextPtr.pointee.value
        nextPtr.pointee.value = nil  // Release the reference

        // Advance tail with release ordering (makes the old node available for reuse)
        tail.store(nextVal, ordering: .releasing)

        return value
    }

    /// Whether the queue is empty.
    ///
    /// - Note: This is only accurate when called from the consumer thread.
    public var isEmpty: Bool {
        let tailVal = tail.load(ordering: .relaxed)
        let tailPtr = UnsafeMutablePointer<Node>(bitPattern: tailVal)!
        let nextVal = Self.next(of: tailPtr).load(ordering: .acquiring)
        return nextVal == 0
    }

    // ============================================================
    // CLOSE OPERATIONS
    // ============================================================

    /// Close the queue. After closing, no more values should be enqueued.
    public func close() {
        closed.store(true, ordering: .releasing)
    }

    /// Whether the queue has been closed.
    public var isClosed: Bool {
        closed.load(ordering: .acquiring)
    }

    /// Receive a value, returning `nil` if the queue is empty.
    ///
    /// This is an alias for `dequeue()` to match channel semantics.
    public func receive() -> T? {
        dequeue()
    }
}
