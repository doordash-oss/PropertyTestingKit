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
//  SimpleRingBuffer.swift
//  PropertyTestingKit
//
//  A simple non-concurrent growing ring buffer optimized for the fuzzing hot path.
//  No Collection protocol conformance to avoid protocol witness overhead.
//

/// A simple non-concurrent ring buffer that grows when full.
///
/// This is optimized for the fuzzing hot path where we need fast:
/// - `isEmpty` checks (single integer comparison)
/// - `removeFirst()` operations (O(1))
/// - `append(contentsOf:)` for bulk additions
///
/// Unlike `Deque`, this has no Collection protocol conformance, avoiding:
/// - Protocol witness table lookups
/// - Generic type metadata instantiation
/// - Copy-on-write indirection
@usableFromInline
struct SimpleRingBuffer<Element>: ~Copyable {
    @usableFromInline
    var storage: UnsafeMutableBufferPointer<Element>

    @usableFromInline
    var head: Int = 0

    @usableFromInline
    var tail: Int = 0

    @usableFromInline
    var _count: Int = 0

    @usableFromInline
    var _capacity: Int

    /// Whether the buffer is empty. O(1), no protocol witness.
    @inlinable
    var isEmpty: Bool { _count == 0 }

    /// Number of elements in the buffer.
    @inlinable
    var count: Int { _count }

    /// Current capacity of the buffer.
    @inlinable
    var capacity: Int { _capacity }

    /// Create a ring buffer with the specified initial capacity.
    @inlinable
    init(minimumCapacity: Int = 16) {
        let capacity = max(minimumCapacity, 16).nextPowerOf2()
        _capacity = capacity
        storage = .allocate(capacity: capacity)
    }

    /// Create a ring buffer initialized with the given elements.
    @inlinable
    init<S: Sequence>(_ elements: S) where S.Element == Element {
        let array = Array(elements)
        let capacity = max(array.count, 16).nextPowerOf2()
        _capacity = capacity
        storage = .allocate(capacity: capacity)

        for (i, element) in array.enumerated() {
            storage.baseAddress!.advanced(by: i).initialize(to: element)
        }
        tail = array.count
        _count = array.count
    }

    deinit {
        // Deinitialize all elements in [head, head + count)
        for i in 0..<_count {
            let index = (head + i) & (_capacity - 1)
            storage.baseAddress!.advanced(by: index).deinitialize(count: 1)
        }
        storage.deallocate()
    }

    /// Append a single element. Grows if necessary.
    @inlinable
    mutating func append(_ element: consuming Element) {
        if _count == _capacity {
            grow()
        }

        storage.baseAddress!.advanced(by: tail).initialize(to: element)
        tail = (tail + 1) & (_capacity - 1)
        _count += 1
    }

    /// Append multiple elements. Grows if necessary.
    @inlinable
    mutating func append(contentsOf elements: [(Element)]) {
        let elementCount = elements.count
        let needed = _count + elementCount
        if needed > _capacity {
            growTo(minimumCapacity: needed)
        }

        for element in elements {
            storage.baseAddress!.advanced(by: tail).initialize(to: element)
            tail = (tail + 1) & (_capacity - 1)
        }
        _count += elementCount
    }

    /// Remove and return the first element, or nil if empty.
    @inlinable
    mutating func removeFirst() -> Element? {
        guard _count > 0 else { return nil }

        let element = storage.baseAddress!.advanced(by: head).move()
        head = (head + 1) & (_capacity - 1)
        _count -= 1
        return element
    }

    /// Remove and return the first element. Traps if empty.
    @inlinable
    mutating func removeFirstUnchecked() -> Element {
        let element = storage.baseAddress!.advanced(by: head).move()
        head = (head + 1) & (_capacity - 1)
        _count -= 1
        return element
    }

    /// Peek at the first element without removing it.
    @inlinable
    func first() -> Element? {
        guard _count > 0 else { return nil }
        return storage[head]
    }

    /// Double the capacity.
    @usableFromInline
    mutating func grow() {
        growTo(minimumCapacity: _capacity * 2)
    }

    /// Grow to at least the specified capacity.
    @usableFromInline
    mutating func growTo(minimumCapacity: Int) {
        let newCapacity = max(minimumCapacity, _capacity * 2).nextPowerOf2()
        let newStorage = UnsafeMutableBufferPointer<Element>.allocate(capacity: newCapacity)

        // Copy elements to new storage, linearizing them
        for i in 0..<_count {
            let oldIndex = (head + i) & (_capacity - 1)
            newStorage.baseAddress!.advanced(by: i).initialize(
                to: storage.baseAddress!.advanced(by: oldIndex).move()
            )
        }

        storage.deallocate()
        storage = newStorage
        head = 0
        tail = _count
        _capacity = newCapacity
    }

    /// Remove all elements.
    @inlinable
    mutating func removeAll() {
        for i in 0..<_count {
            let index = (head + i) & (_capacity - 1)
            storage.baseAddress!.advanced(by: index).deinitialize(count: 1)
        }
        head = 0
        tail = 0
        _count = 0
    }
}

// MARK: - Sendable

extension SimpleRingBuffer: @unchecked Sendable where Element: Sendable {}

// MARK: - Int Extension

extension Int {
    /// Round up to the next power of 2.
    @inlinable
    func nextPowerOf2() -> Int {
        guard self > 0 else { return 1 }
        guard self <= (Int.max >> 1) + 1 else { return self }
        return 1 << (Int.bitWidth - (self - 1).leadingZeroBitCount)
    }
}
