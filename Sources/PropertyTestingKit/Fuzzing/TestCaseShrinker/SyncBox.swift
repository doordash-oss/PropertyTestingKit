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

//
//  SyncBox.swift
//  PropertyTestingKit
//
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
final class SyncBox<T>: @unchecked Sendable {
    private var storage: T
    private let lock = NSLock()

    /// Read or write the wrapped value in a thread-safe manner.
    var value: T {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            storage = newValue
        }
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
