//
//  ThreadSafeCollector.swift
//  PropertyTestingKit
//
//  Thread-safe utilities for collecting test data in concurrent fuzz tests.
//

import Foundation

/// An actor-based wrapper for thread-safe access to values.
///
/// Use this when you need actor-isolated access to a value with atomic compound operations.
///
/// Example:
/// ```swift
/// let counter = Synchronized(0)
/// await counter.update { $0 += 1 }
///
/// let seenValues = Synchronized(Set<Int>())
/// await seenValues.update { $0.insert(42) }
///
/// // Return values from update
/// let count = await counter.update {
///     $0 += 1
///     return $0
/// }
/// ```
actor Synchronized<T: Sendable>: Sendable {
    private var storage: T

    var value: T {
        storage
    }

    init(_ value: T) {
        self.storage = value
    }

    /// Atomically update the value, optionally returning a result.
    @discardableResult
    func update<Result: Sendable>(_ transform: (inout T) throws -> Result) rethrows -> Result {
        try transform(&storage)
    }
}

extension Synchronized where T == Int {
    @discardableResult
    func increment() -> Int {
        storage += 1
        return storage
    }
}

/// A lock-based wrapper for synchronous thread-safe access to values.
///
/// Use this when you need synchronous access to a value across threads.
/// Unlike `Synchronized` (which is an actor), this uses a lock and provides
/// synchronous access suitable for use with non-async APIs like `DateClient.now`.
///
/// Example:
/// ```swift
/// let time = SyncBox(Date())
/// let now = time.value  // Synchronous access
/// time.update { $0.addingTimeInterval(1) }
/// ```
final class SyncBox<T>: @unchecked Sendable {
    private var storage: T
    private let lock = NSLock()

    var value: T {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    init(_ value: T) {
        self.storage = value
    }

    /// Atomically update the value with a transform closure.
    @discardableResult
    func update<Result>(_ transform: (inout T) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try transform(&storage)
    }
}
