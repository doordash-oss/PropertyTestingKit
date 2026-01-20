//
//  VyukovChannel.swift
//  PropertyTestingKit
//
//  Implementation of Dmitry Vyukov's MPSC queue.
//  Uses a single XCHG per push for wait-free producers.
//
//  Reference: https://www.1024cores.net/home/lock-free-algorithms/queues/intrusive-mpsc-node-based-queue
//
//  ## Trade-offs vs Ring Buffer
//
//  - **Pro**: Wait-free producers (single atomic op, no retries)
//  - **Pro**: Unbounded capacity (no drops)
//  - **Con**: Allocation per push
//  - **Con**: Poor cache locality (linked list traversal)
//

import Atomics
import Foundation

/// A node in the Vyukov MPSC queue.
/// Uses Unmanaged for atomic pointer operations.
private final class VyukovNode<Element>: @unchecked Sendable {
    var value: Element?
    let next: UnsafeAtomic<UInt>  // Stores Unmanaged pointer bits, 0 = nil

    init(_ value: Element?) {
        self.value = value
        self.next = .create(0)
    }

    deinit {
        next.destroy()
    }

    func storeNextReleasing(_ node: VyukovNode<Element>?) {
        let bits = node.map { UInt(bitPattern: Unmanaged.passRetained($0).toOpaque()) } ?? 0
        next.store(bits, ordering: .releasing)
    }

    func loadNextAcquiring() -> VyukovNode<Element>? {
        let bits = next.load(ordering: .acquiring)
        guard bits != 0 else { return nil }
        return Unmanaged<VyukovNode<Element>>.fromOpaque(UnsafeRawPointer(bitPattern: bits)!).takeUnretainedValue()
    }
}

/// Vyukov's MPSC queue - wait-free producers using single XCHG.
///
/// This queue is unbounded and allocates a node per push.
/// Producers never block or retry - each push is exactly one atomic exchange.
public final class VyukovChannel<Element: Sendable>: @unchecked Sendable {
    // Tail: producers XCHG here to append (stores Unmanaged pointer bits)
    private let tail: UnsafeAtomic<UInt>

    // Head: consumer reads from here
    private var head: VyukovNode<Element>

    // Closed flag
    private let _closed: ManagedAtomic<Bool>

    /// Whether the channel has been closed.
    public var isClosed: Bool {
        _closed.load(ordering: .acquiring)
    }

    /// Creates a new Vyukov MPSC queue.
    public init() {
        // Start with a stub node - simplifies empty queue handling
        let stubNode = VyukovNode<Element>(nil)
        self.head = stubNode
        // Store the stub node as the initial tail
        let stubBits = UInt(bitPattern: Unmanaged.passRetained(stubNode).toOpaque())
        self.tail = .create(stubBits)
        self._closed = ManagedAtomic(false)
    }

    deinit {
        // Drain remaining nodes to release them
        while tryRecv() != nil {}
        // Release the stub/head
        let headBits = UInt(bitPattern: Unmanaged.passUnretained(head).toOpaque())
        if headBits != 0 {
            Unmanaged<VyukovNode<Element>>.fromOpaque(UnsafeRawPointer(bitPattern: headBits)!).release()
        }
        tail.destroy()
    }

    /// Sends a message to the channel.
    ///
    /// This method is wait-free - exactly one atomic operation, no retries.
    /// Each call allocates a new node.
    @inline(__always)
    public func send(_ element: consuming Element) {
        let node = VyukovNode(element)
        let nodeBits = UInt(bitPattern: Unmanaged.passRetained(node).toOpaque())

        // Single XCHG: atomically swap tail with our new node
        let prevBits = tail.exchange(nodeBits, ordering: .acquiringAndReleasing)

        // Get the previous tail node
        let prev = Unmanaged<VyukovNode<Element>>.fromOpaque(UnsafeRawPointer(bitPattern: prevBits)!).takeUnretainedValue()

        // Link the previous tail to our new node
        prev.storeNextReleasing(node)
    }

    /// Attempts to receive a message without blocking.
    @inline(__always)
    public func tryRecv() -> Element? {
        let headNode = head
        var next = headNode.loadNextAcquiring()

        // If head has no value (stub), try to advance past it
        if headNode.value == nil {
            guard let nextNode = next else {
                return nil  // Queue is empty
            }
            head = nextNode
            next = nextNode.loadNextAcquiring()
            // Release the old stub
            Unmanaged.passUnretained(headNode).release()
        }

        // Current head should have a value
        let currentHead = head

        if let nextNode = next {
            // There's a next node, safe to consume current head
            let value = currentHead.value
            currentHead.value = nil
            head = nextNode
            Unmanaged.passUnretained(currentHead).release()
            return value
        }

        // Check if current head is also the tail
        let tailBits = tail.load(ordering: .acquiring)
        let currentHeadBits = UInt(bitPattern: Unmanaged.passUnretained(currentHead).toOpaque())

        if currentHeadBits != tailBits {
            // Producer is mid-push (XCHG'd but not linked next yet)
            return nil
        }

        // Head == Tail, and no next - this node is the only one
        // If it has a value, we need to be careful
        if currentHead.value != nil {
            // Create new stub and swap it as tail
            let newStub = VyukovNode<Element>(nil)
            let stubBits = UInt(bitPattern: Unmanaged.passRetained(newStub).toOpaque())

            let prevBits = tail.exchange(stubBits, ordering: .acquiringAndReleasing)
            let prev = Unmanaged<VyukovNode<Element>>.fromOpaque(UnsafeRawPointer(bitPattern: prevBits)!).takeUnretainedValue()
            prev.storeNextReleasing(newStub)

            // Now try again - the structure should be valid
            if let nextNode = currentHead.loadNextAcquiring() {
                let value = currentHead.value
                currentHead.value = nil
                head = nextNode
                Unmanaged.passUnretained(currentHead).release()
                return value
            }
        }

        return nil
    }

    /// Receives a message, spinning until one is available.
    @inline(__always)
    public func recv() -> Element? {
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

// MARK: - Sequence Conformance

extension VyukovChannel: Sequence {
    public func makeIterator() -> VyukovChannelIterator<Element> {
        VyukovChannelIterator(channel: self)
    }
}

public struct VyukovChannelIterator<Element: Sendable>: IteratorProtocol {
    let channel: VyukovChannel<Element>

    public mutating func next() -> Element? {
        channel.recv()
    }
}
