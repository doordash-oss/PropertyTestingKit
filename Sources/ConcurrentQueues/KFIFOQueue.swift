import Atomics
import Darwin

// Use Swift Atomics' built-in DoubleWord for 128-bit atomic operations
@usableFromInline
typealias DoubleWord = Atomics.DoubleWord

// MARK: - XorShift64 RNG

@usableFromInline
struct XorShift64 {
    @usableFromInline var state: UInt64

    @inlinable
    init(seed: UInt64) {
        self.state = seed == 0 ? 0xDEADBEEF : seed
    }

    @inlinable
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

/// Thread-local RNG using pthread TLS for queue slot randomization.
@usableFromInline
enum ThreadLocalRNG {
    @usableFromInline
    static let _key: pthread_key_t = {
        var key = pthread_key_t()
        pthread_key_create(&key, nil)
        return key
    }()

    @inlinable
    static func random(upperBound: Int) -> Int {
        let rawPtr = pthread_getspecific(_key)
        var state: UInt64
        if rawPtr == nil {
            state = UInt64(bitPattern: Int64(Int(bitPattern: pthread_self())))
            if state == 0 { state = 0xDEADBEEF }
        } else {
            state = UInt64(UInt(bitPattern: rawPtr))
        }

        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17

        pthread_setspecific(_key, UnsafeRawPointer(bitPattern: UInt(truncatingIfNeeded: state)))
        return Int(state % UInt64(upperBound))
    }
}

// MARK: - Direct Storage Helpers

@inlinable
func _canStoreDirectly<T>(_ type: T.Type) -> Bool {
    MemoryLayout<T>.size <= 7 && MemoryLayout<T>.alignment <= MemoryLayout<UInt>.alignment
}

@inlinable
func _encodeDirectValue<T>(_ value: T) -> UInt {
    var encoded: UInt = 0
    withUnsafeBytes(of: value) { bytes in
        withUnsafeMutableBytes(of: &encoded) { dest in
            dest.copyMemory(from: bytes)
        }
    }
    return encoded | (1 << 63)
}

@inlinable
func _decodeDirectValue<T>(_ encoded: UInt) -> T {
    var value = encoded & ~(UInt(1) << 63)
    return withUnsafeBytes(of: &value) { bytes in
        bytes.load(as: T.self)
    }
}

// MARK: - RawBox

@usableFromInline
enum RawBox<T> {
    @inlinable
    static func allocate(_ value: T) -> UInt {
        let ptr = UnsafeMutablePointer<T>.allocate(capacity: 1)
        ptr.initialize(to: value)
        return UInt(bitPattern: ptr)
    }

    @inlinable
    static func takeValue(_ boxPtr: UInt) -> T {
        let ptr = UnsafeMutablePointer<T>(bitPattern: boxPtr)!
        let value = ptr.move()
        ptr.deallocate()
        return value
    }

    @inlinable
    static func deallocate(_ boxPtr: UInt) {
        let ptr = UnsafeMutablePointer<T>(bitPattern: boxPtr)!
        ptr.deinitialize(count: 1)
        ptr.deallocate()
    }
}

// MARK: - RawSegment

@usableFromInline
// Slots offset must be 16-byte aligned for 128-bit atomic operations
// Layout: next (16 bytes) + k (8 bytes) + padding (8 bytes) = 32 bytes
let _rawSegmentSlotsOffset: Int = 32

@usableFromInline
struct RawSegment {
    @usableFromInline let ptr: UnsafeMutableRawPointer

    @inlinable
    init(ptr: UnsafeMutableRawPointer) {
        self.ptr = ptr
    }

    @inlinable
    var next: UnsafeAtomic<DoubleWord> {
        UnsafeAtomic<DoubleWord>(at: ptr.assumingMemoryBound(to: DoubleWord.AtomicRepresentation.self))
    }

    @inlinable
    var k: Int {
        ptr.advanced(by: MemoryLayout<DoubleWord.AtomicRepresentation>.stride)
            .assumingMemoryBound(to: Int.self).pointee
    }

    @inlinable
    func slot(at index: Int) -> UnsafeAtomic<DoubleWord> {
        let slotsBase = ptr.advanced(by: _rawSegmentSlotsOffset)
            .assumingMemoryBound(to: DoubleWord.AtomicRepresentation.self)
        return UnsafeAtomic<DoubleWord>(at: slotsBase.advanced(by: index))
    }

    @inlinable
    var asUInt: UInt { UInt(bitPattern: ptr) }

    @inlinable
    static func from(_ value: UInt) -> RawSegment {
        RawSegment(ptr: UnsafeMutableRawPointer(bitPattern: value)!)
    }

    @inlinable
    static func create(k: Int) -> RawSegment {
        let totalSize = _rawSegmentSlotsOffset + k * MemoryLayout<DoubleWord.AtomicRepresentation>.stride
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: totalSize, alignment: 16)

        ptr.assumingMemoryBound(to: DoubleWord.AtomicRepresentation.self)
            .initialize(to: DoubleWord.AtomicRepresentation(DoubleWord(first: 0, second: 0)))

        ptr.advanced(by: MemoryLayout<DoubleWord.AtomicRepresentation>.stride)
            .assumingMemoryBound(to: Int.self).initialize(to: k)

        let slotsBase = ptr.advanced(by: _rawSegmentSlotsOffset)
            .assumingMemoryBound(to: DoubleWord.AtomicRepresentation.self)
        for i in 0..<k {
            slotsBase.advanced(by: i).initialize(to: DoubleWord.AtomicRepresentation(DoubleWord(first: 0, second: 0)))
        }

        return RawSegment(ptr: ptr)
    }

    @inlinable
    func destroy() { ptr.deallocate() }
}

// MARK: - KFIFOQueue

final class KFIFOQueue<T>: @unchecked Sendable {

    @usableFromInline let k: Int
    @usableFromInline let useDirectStorage: Bool
    @usableFromInline let _headPtr: UnsafeMutablePointer<DoubleWord.AtomicRepresentation>
    @usableFromInline let _tailPtr: UnsafeMutablePointer<DoubleWord.AtomicRepresentation>
    @usableFromInline let _closedPtr: UnsafeMutablePointer<Bool.AtomicRepresentation>
    @usableFromInline let _countPtr: UnsafeMutablePointer<Int.AtomicRepresentation>

    @inlinable var head: UnsafeAtomic<DoubleWord> { UnsafeAtomic<DoubleWord>(at: _headPtr) }
    @inlinable var tail: UnsafeAtomic<DoubleWord> { UnsafeAtomic<DoubleWord>(at: _tailPtr) }
    @inlinable var closed: UnsafeAtomic<Bool> { UnsafeAtomic(at: _closedPtr) }
    @inlinable var count: UnsafeAtomic<Int> { UnsafeAtomic(at: _countPtr) }

    public init(k: Int) {
        precondition(k > 0, "k must be positive")
        self.k = k
        self.useDirectStorage = _canStoreDirectly(T.self)

        let segment = RawSegment.create(k: k)
        let initialValue = DoubleWord(first: segment.asUInt, second: 0)

        self._headPtr = .allocate(capacity: 1)
        self._headPtr.initialize(to: DoubleWord.AtomicRepresentation(initialValue))

        self._tailPtr = .allocate(capacity: 1)
        self._tailPtr.initialize(to: DoubleWord.AtomicRepresentation(initialValue))

        self._closedPtr = .allocate(capacity: 1)
        self._closedPtr.initialize(to: Bool.AtomicRepresentation(false))

        self._countPtr = .allocate(capacity: 1)
        self._countPtr.initialize(to: Int.AtomicRepresentation(0))
    }

    deinit {
        var currentPtr = head.load(ordering: .acquiring).first
        while currentPtr != 0 {
            let seg = RawSegment.from(currentPtr)
            let nextPtr = seg.next.load(ordering: .acquiring).first

            if !useDirectStorage {
                for i in 0..<k {
                    let slot = seg.slot(at: i).load(ordering: .acquiring)
                    if slot.first != 0 {
                        RawBox<T>.deallocate(slot.first)
                    }
                }
            }

            seg.destroy()
            currentPtr = nextPtr
        }

        _headPtr.deinitialize(count: 1)
        _headPtr.deallocate()
        _tailPtr.deinitialize(count: 1)
        _tailPtr.deallocate()
        _closedPtr.deinitialize(count: 1)
        _closedPtr.deallocate()
        _countPtr.deinitialize(count: 1)
        _countPtr.deallocate()
    }

    @discardableResult
    @inlinable
    public func enqueue(_ item: T) -> Bool {
        // Check if closed before attempting to enqueue
        if isClosed { return false }

        var encodedPtr: UInt = 0

        while true {
            let tailOld = tail.load(ordering: .acquiring)
            _ = head.load(ordering: .acquiring)

            let tailSegment = RawSegment.from(tailOld.first)
            let (itemOld, index) = findEmptySlot(in: tailSegment)

            if tailOld == tail.load(ordering: .acquiring) {
                if itemOld.first == 0 {
                    if encodedPtr == 0 {
                        encodedPtr = useDirectStorage ? _encodeDirectValue(item) : RawBox<T>.allocate(item)
                    }

                    let itemNew = DoubleWord(first: encodedPtr, second: itemOld.second &+ 1)

                    if tailSegment.slot(at: index).compareExchange(
                        expected: itemOld, desired: itemNew, ordering: .acquiringAndReleasing
                    ).exchanged {
                        if committed(tailOld: tailOld, itemNew: itemNew, index: index) {
                            count.wrappingIncrement(ordering: .relaxed)
                            return true
                        }
                        encodedPtr = 0
                    }
                } else {
                    advanceTail(tailOld)
                }
            }
        }
    }

    @inlinable
    public func dequeue() -> T? {
        // Fast path: check count before scanning
        if count.load(ordering: .relaxed) <= 0 {
            return nil
        }

        while true {
            let headOld = head.load(ordering: .acquiring)
            let headSegment = RawSegment.from(headOld.first)
            let (itemOld, index) = findItem(in: headSegment)

            if headOld == head.load(ordering: .acquiring) {
                if itemOld.first != 0 {
                    let itemEmpty = DoubleWord(first: 0, second: itemOld.second &+ 1)

                    if headSegment.slot(at: index).compareExchange(
                        expected: itemOld, desired: itemEmpty, ordering: .acquiringAndReleasing
                    ).exchanged {
                        count.wrappingDecrement(ordering: .relaxed)
                        return decodeItem(itemOld.first)
                    }
                } else {
                    let tailOld = tail.load(ordering: .acquiring)
                    if headOld.first == tailOld.first {
                        return nil
                    }
                    advanceHead(headOld)
                }
            }
        }
    }

    @inlinable
    public func close() {
        closed.store(true, ordering: .releasing)
    }

    @inlinable
    public var isClosed: Bool {
        closed.load(ordering: .acquiring)
    }

    public func receive() -> T? {
        while true {
            if let item = dequeue() { return item }
            if isClosed { return dequeue() }
        }
    }

    // MARK: - Private Helpers

    @inline(__always)
    @inlinable
    func findEmptySlot(in segment: RawSegment) -> (DoubleWord, Int) {
        let startIndex = ThreadLocalRNG.random(upperBound: k)
        var i = 0
        while i < k {
            let index = (startIndex &+ i) % k
            let slotValue = segment.slot(at: index).load(ordering: .acquiring)
            if slotValue.first == 0 {
                return (slotValue, index)
            }
            i &+= 1
        }
        let lastIndex = (startIndex &+ k &- 1) % k
        return (segment.slot(at: lastIndex).load(ordering: .acquiring), lastIndex)
    }

    @inline(__always)
    @inlinable
    func findItem(in segment: RawSegment) -> (DoubleWord, Int) {
        let startIndex = ThreadLocalRNG.random(upperBound: k)
        var i = 0
        while i < k {
            let index = (startIndex &+ i) % k
            let slotValue = segment.slot(at: index).load(ordering: .acquiring)
            if slotValue.first != 0 {
                return (slotValue, index)
            }
            i &+= 1
        }
        let lastIndex = (startIndex &+ k &- 1) % k
        return (segment.slot(at: lastIndex).load(ordering: .acquiring), lastIndex)
    }

    @usableFromInline
    @inlinable
    func committed(tailOld: DoubleWord, itemNew: DoubleWord, index: Int) -> Bool {
        let tailSegment = RawSegment.from(tailOld.first)

        // Line 22-23: Check if item was already consumed
        if tailSegment.slot(at: index).load(ordering: .acquiring) != itemNew {
            return true
        }

        // Line 24-25: Get current head and tail
        let headCurrent = head.load(ordering: .acquiring)

        // Line 26: Prepare empty item for potential rollback
        let itemEmpty = DoubleWord(first: 0, second: itemNew.second &+ 1)

        // Compute reachability ONCE
        let reachable = isReachable(target: tailOld.first, from: headCurrent.first)

        // Line 27-28: in_queue_after_head - segment is in queue past the head
        if tailOld.first != headCurrent.first && reachable {
            return true
        }

        // Line 29-31: not_in_queue - segment has been removed from queue
        if !reachable {
            // Try to rollback our enqueue
            if !tailSegment.slot(at: index).compareExchange(
                expected: itemNew, desired: itemEmpty, ordering: .acquiringAndReleasing
            ).exchanged {
                // CAS failed - someone consumed our item, so it's committed
                return true
            }
            // CAS succeeded - we rolled back, deallocate if needed
            if !useDirectStorage {
                RawBox<T>.deallocate(itemNew.first)
            }
            return false
        }

        // Line 32-37: in_queue_at_head - segment is at the head position
        // Try to bump head version to confirm our position
        let headNew = DoubleWord(first: headCurrent.first, second: headCurrent.second &+ 1)
        if head.compareExchange(expected: headCurrent, desired: headNew, ordering: .acquiringAndReleasing).exchanged {
            return true
        }

        // Head changed, try to rollback
        if !tailSegment.slot(at: index).compareExchange(
            expected: itemNew, desired: itemEmpty, ordering: .acquiringAndReleasing
        ).exchanged {
            // CAS failed - someone consumed our item
            return true
        }

        // CAS succeeded - we rolled back
        if !useDirectStorage {
            RawBox<T>.deallocate(itemNew.first)
        }
        return false
    }

    @usableFromInline
    @inlinable
    func isReachable(target: UInt, from start: UInt) -> Bool {
        var current = start
        while current != 0 {
            if current == target { return true }
            current = RawSegment.from(current).next.load(ordering: .acquiring).first
        }
        return false
    }

    @usableFromInline
    @inlinable
    func advanceTail(_ tailOld: DoubleWord) {
        let tailSegment = RawSegment.from(tailOld.first)
        var next = tailSegment.next.load(ordering: .acquiring)

        if next.first == 0 {
            let newSegment = RawSegment.create(k: k)
            let newNext = DoubleWord(first: newSegment.asUInt, second: next.second &+ 1)

            let result = tailSegment.next.compareExchange(
                expected: next, desired: newNext, ordering: .acquiringAndReleasing
            )

            if result.exchanged {
                next = newNext
            } else {
                newSegment.destroy()
                next = result.original
            }
        }

        if next.first != 0 {
            let newTail = DoubleWord(first: next.first, second: tailOld.second &+ 1)
            _ = tail.compareExchange(expected: tailOld, desired: newTail, ordering: .acquiringAndReleasing)
        }
    }

    @usableFromInline
    @inlinable
    func advanceHead(_ headOld: DoubleWord) {
        let next = RawSegment.from(headOld.first).next.load(ordering: .acquiring)
        if next.first != 0 {
            let newHead = DoubleWord(first: next.first, second: headOld.second &+ 1)
            _ = head.compareExchange(expected: headOld, desired: newHead, ordering: .acquiringAndReleasing)
        }
    }

    @inline(__always)
    @usableFromInline
    @inlinable
    func decodeItem(_ encoded: UInt) -> T {
        useDirectStorage ? _decodeDirectValue(encoded) : RawBox<T>.takeValue(encoded)
    }
}
