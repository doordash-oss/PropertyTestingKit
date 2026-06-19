// Copyright 2026 DoorDash, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

//  Lock-based wrapper for synchronous thread-safe access to values.
//

import Foundation

/// A lock-based wrapper for synchronous thread-safe access to values.
///
/// Use this when you need synchronous access to a value across threads,
/// such as in callbacks or closures that must be Sendable.
///
/// Example:
/// ```swift
/// let flag = SyncBox(false)
/// flag.value = true  // Thread-safe write
/// let current = flag.value  // Thread-safe read
/// ```
public final class SyncBox<T>: @unchecked Sendable {
    private var storage: T
    private let lock = NSLock()
    /// Non-nil only when PTK_LOCK_METRICS is on (or `forceMetrics`). Off by
    /// default — `acquire()` then takes the plain `lock.lock()` path.
    private let metrics: LockMetrics?

    /// Read or write the wrapped value in a thread-safe manner.
    public var value: T {
        get {
            acquire()
            defer { lock.unlock() }
            return storage
        }
        set {
            acquire()
            defer { lock.unlock() }
            storage = newValue
        }
    }

    /// - Parameters:
    ///   - label: identifies this box in the PTK_LOCK_METRICS dump (the
    ///     call-site, e.g. "hitCountBuckets.state"). Empty = unlabeled.
    ///   - forceMetrics: enable counting regardless of the env var (tests).
    public init(_ value: T, label: String = "", forceMetrics: Bool = false) {
        self.storage = value
        self.metrics = label.isEmpty && !forceMetrics
            ? nil
            : LockMetrics.register(label, force: forceMetrics)
    }

    /// Take the lock, counting the acquisition (and whether it was contended)
    /// when metrics are enabled. Zero overhead when disabled.
    private func acquire() {
        if let m = metrics {
            if !lock.try() {
                m.contended.wrappingIncrement(ordering: .relaxed)
                lock.lock()
            }
            m.acquisitions.wrappingIncrement(ordering: .relaxed)
        } else {
            lock.lock()
        }
    }

    /// Atomically update the value with a transform closure.
    @discardableResult
    public func update<Result>(_ transform: (inout T) throws -> Result) rethrows -> Result {
        acquire()
        defer { lock.unlock() }
        return try transform(&storage)
    }
}
