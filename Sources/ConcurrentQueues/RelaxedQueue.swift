//
//  RelaxedQueue.swift
//  PropertyTestingKit
//
//  Common protocol for relaxed ordering queue implementations.
//  All implementations trade strict FIFO ordering for better throughput.
//

/// A bounded queue that may deliver elements out of strict FIFO order.
///
/// Relaxed queues trade ordering guarantees for improved throughput under
/// contention. Different implementations offer different relaxation strategies.
public protocol RelaxedQueue<Element>: Sendable {
    associatedtype Element: Sendable

    /// Sends an element to the queue.
    ///
    /// This operation is thread-safe for multiple concurrent producers.
    /// If the queue is full, this will spin-wait until space is available.
    ///
    /// - Parameter element: The element to send.
    func send(_ element: consuming Element)

    /// Attempts to receive an element without blocking.
    ///
    /// - Returns: An element if available, or `nil` if the queue is empty.
    func tryRecv() -> Element?

    /// Receives an element, spinning until one is available or the queue is closed.
    ///
    /// - Returns: An element if available, or `nil` if the queue is closed and empty.
    func recv() -> Element?

    /// Closes the queue. After closing, `recv()` will return `nil` once empty.
    func close()

    /// Whether the queue has been closed.
    var isClosed: Bool { get }
}
