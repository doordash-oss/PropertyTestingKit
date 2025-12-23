//
//  ThreadSafeCollector.swift
//  PropertyTestingKit
//
//  Thread-safe utilities for collecting test data in concurrent fuzz tests.
//

import Foundation

/// A thread-safe collector for gathering test inputs during concurrent fuzz testing.
///
/// Use this instead of `nonisolated(unsafe)` arrays when test closures need to
/// collect inputs that will be verified after fuzzing completes.
///
/// Example:
/// ```swift
/// let collector = ThreadSafeCollector<String>()
/// try await fuzz { (input: String) in
///     await collector.append(input)
/// }
/// let inputs = await collector.values
/// #expect(inputs.contains("expected"))
/// ```
actor ThreadSafeCollector<T: Sendable> {
    private var storage: [T] = []

    init() {}

    /// Append a value to the collection.
    func append(_ value: T) {
        storage.append(value)
    }

    /// Append multiple values to the collection.
    func append(contentsOf values: [T]) {
        storage.append(contentsOf: values)
    }

    /// Get all collected values.
    var values: [T] {
        storage
    }

    /// Get the count of collected values.
    var count: Int {
        storage.count
    }

    /// Check if the collection is empty.
    var isEmpty: Bool {
        storage.isEmpty
    }

    /// Check if collection contains an element (requires Equatable).
    func contains(_ element: T) -> Bool where T: Equatable {
        storage.contains(element)
    }

    /// Check if collection contains an element matching a predicate.
    func contains(where predicate: (T) -> Bool) -> Bool {
        storage.contains(where: predicate)
    }

    /// Clear all collected values.
    func clear() {
        storage.removeAll()
    }
}

/// A thread-safe flag for tracking boolean state in concurrent fuzz tests.
///
/// Example:
/// ```swift
/// let sawEmpty = ThreadSafeFlag()
/// try await fuzz { (input: String) in
///     if input.isEmpty { sawEmpty.set() }
/// }
/// #expect(sawEmpty.isSet)
/// ```
final class ThreadSafeFlag: @unchecked Sendable {
    private var flag: Bool
    private let lock = NSLock()

    init(_ initialValue: Bool = false) {
        flag = initialValue
    }

    /// Set the flag to true.
    func set() {
        lock.lock()
        defer { lock.unlock() }
        flag = true
    }

    /// Clear the flag to false.
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        flag = false
    }

    /// Check if the flag is set.
    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }
}

/// A thread-safe wrapper for Date values in concurrent tests.
///
/// Example:
/// ```swift
/// let currentTime = ThreadSafeDate(Date(timeIntervalSince1970: 0))
/// try await fuzz { (input: String) in
///     currentTime.addInterval(1.0)
/// }
/// print(currentTime.value)
/// ```
final class ThreadSafeDate: @unchecked Sendable {
    private var date: Date
    private let lock = NSLock()

    init(_ date: Date = Date()) {
        self.date = date
    }

    /// Get the current date value.
    var value: Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    /// Add a time interval to the current date.
    func addInterval(_ interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        date = date.addingTimeInterval(interval)
    }

    /// Set the date to a new value.
    func set(_ newDate: Date) {
        lock.lock()
        defer { lock.unlock() }
        date = newDate
    }
}

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
