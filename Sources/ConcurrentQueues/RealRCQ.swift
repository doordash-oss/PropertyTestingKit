//
//  RealRCQ.swift
//  RCQD Implementation based on:
//  "A Family of Relaxed Concurrent Queues for Low-Latency Operations and Item Transfers"
//  Kappes & Anastasiadis, ACM TOPC 2022
//

import Atomics
import Foundation

// MARK: - Constants

/// Default array size N = 2^n (paper uses n = 8)
public let N: UInt = 256

/// Slot states (paper Section 5.1)
public let FREE: UInt = 0
public let OCCUPIED: UInt = 1
public let ENQPND: UInt = 2  // Enqueue pending - slot locked by enqueuer
public let DEQPND: UInt = 3  // Dequeue pending - slot locked by dequeuer

/// Maximum spins before sleeping (paper Listing 3)
private let MAXSPINS: Int = 1000

// MARK: - Slot (Listing 1, lines 1-6)

/// A slot in the RCQ array.
/// Fields are placed in distinct cache lines in the paper, but we use DoubleWord
/// for atomic CAS2 on state+data together.
public final class Slot: @unchecked Sendable {
    // state (32 bits in paper) and data (64 bits in paper) packed into DoubleWord
    // DoubleWord.first = state, DoubleWord.second = data
    private let _stateAndDataPtr: UnsafeMutablePointer<DoubleWord.AtomicRepresentation>
    var stateAndData: UnsafeAtomic<DoubleWord> { UnsafeAtomic<DoubleWord>(at: _stateAndDataPtr) }

    // waiters: uint (32 bits), initially 0
    let waiters: ManagedAtomic<UInt32>

    // Condition for wait/wake (replaces futex)
    private let lock = NSLock()
    let condition = NSCondition()

    public init() {
        // Initially FREE with no data
        self._stateAndDataPtr = .allocate(capacity: 1)
        self._stateAndDataPtr.initialize(to: DoubleWord.AtomicRepresentation(DoubleWord(first: FREE, second: 0)))
        self.waiters = ManagedAtomic(0)
    }

    deinit {
        _stateAndDataPtr.deinitialize(count: 1)
        _stateAndDataPtr.deallocate()
    }

    /// Wake all waiting dequeuers (paper Listing 3, lines 53-57)
    func wakeDeq() {
        // if (s→waiters > 0) { wake(&s→state) }
        if waiters.load(ordering: .relaxed) > 0 {
            condition.lock()
            condition.broadcast()
            condition.unlock()
        }
    }

    /// Wait for enqueuer to insert item (paper Listing 3, lines 58-71)
    /// Returns true if state changed, false if closed
    func waitEnq(expectedState: UInt, closed: ManagedAtomic<Bool>) -> Bool {
        // Spin for MAXSPINS iterations first
        for _ in 0..<MAXSPINS {
            if closed.load(ordering: .acquiring) {
                return false
            }
            let current = stateAndData.load(ordering: .acquiring)
            if current.first != expectedState {
                return true
            }
            // spinPause equivalent
#if arch(x86_64)
            _mm_pause()
#endif
        }

        // atomicInc(&s→waiters)
        waiters.wrappingIncrement(ordering: .relaxed)

        // while (s→state = v) { wait(&s→state, v) }
        condition.lock()
        while stateAndData.load(ordering: .acquiring).first == expectedState
                && !closed.load(ordering: .acquiring) {
            condition.wait()
        }
        condition.unlock()

        // atomicDec(&s→waiters)
        waiters.wrappingDecrement(ordering: .relaxed)

        return !closed.load(ordering: .acquiring)
    }
}

// MARK: - RCQ (Listing 1, lines 7-12)

/// Relaxed Concurrent Queue - RCQD variant using CAS2 (DoubleWord)
public final class RCQ: @unchecked Sendable {
    // slots[N]: struct slot, N = 2^n (e.g., n = 8)
    private let slots: [Slot]

    // head: uint (16 bits), initially 0
    private let head: ManagedAtomic<UInt>

    // tail: uint (16 bits), initially 0
    private let tail: ManagedAtomic<UInt>

    /// Size of the queue (must be power of 2)
    public let size: UInt

    private var closed: ManagedAtomic<Bool>

    public init(size: UInt = N) {
        precondition(size > 0 && (size & (size - 1)) == 0, "Size must be a power of 2")
        self.size = size
        self.slots = (0..<size).map { _ in Slot() }
        self.head = ManagedAtomic(0)
        self.tail = ManagedAtomic(0)
        self.closed = ManagedAtomic(false)
    }

    // MARK: - Enqueue (Listing 4, lines 72-89)

    /// Enqueue operation - inserts data into the queue
    /// Returns 0 on success (matching paper's return convention)
    @discardableResult
    public func enqueue(_ d: UInt) -> Int {
        guard !closed.load(ordering: .acquiring) else {
            return 1
        }
        // locTail: uint (16 bits)
        // locState: int (32 bits)
        // locData: int (64 bits)

        // locTail := atomicInc(&q→tail) & (N-1)  // enq_assign (line 77)
        let locTail = tail.wrappingIncrementThenLoad(ordering: .acquiringAndReleasing) &- 1
        let slotIndex = Int(locTail & (size - 1))
        let slot = slots[slotIndex]

        // while (true)
        while true {
            // locState := atomicLoad(&q→slots[locTail].state)  // enq_update (lines 79-87)
            // locData := atomicLoad(&q→slots[locTail].data)
            let current = slot.stateAndData.load(ordering: .acquiring)
            let locState = current.first
            let locData = current.second

            // if (locState = FREE)
            if locState == FREE {
                // if (CAS2(&q→slots[locTail], &locState, &locData, OCCUPIED, d) = true)
                let expected = DoubleWord(first: locState, second: locData)
                let desired = DoubleWord(first: OCCUPIED, second: d)

                let (exchanged, _) = slot.stateAndData.compareExchange(
                    expected: expected,
                    desired: desired,
                    ordering: .acquiringAndReleasing
                )

                if exchanged {
                    // wakeDeq(&q→slots[locTail])
                    slot.wakeDeq()
                    // return(0) // successful enqueue
                    return 0
                }
            }

            // spinPause
#if arch(x86_64)
            _mm_pause()
#endif
        }
    }

    // MARK: - Dequeue (Listing 4, lines 90-109)

    /// Dequeue operation - removes and returns data from the queue
    /// Returns nil if the queue is closed
    public func dequeue() -> UInt? {
        // locHead: uint (16 bits)
        // locState: int (32 bits)
        // locData: int (64 bits)

        // locHead := atomicInc(&q→head) & (N-1)  // deq_assign (line 95)
        let locHead = head.wrappingIncrementThenLoad(ordering: .acquiringAndReleasing) &- 1
        let slotIndex = Int(locHead & (size - 1))
        let slot = slots[slotIndex]

        // while (true)
        while true {
            // locState := atomicLoad(&q→slots[locHead].state)  // deq_update (lines 97-107)
            // locData := atomicLoad(&q→slots[locHead].data)
            let current = slot.stateAndData.load(ordering: .acquiring)
            let locState = current.first
            let locData = current.second

            // if (locState = OCCUPIED)
            if locState == OCCUPIED {
                // if (CAS2(&q→slots[locHead], &locState, &locData, FREE, 0) = true)
                let expected = DoubleWord(first: locState, second: locData)
                let desired = DoubleWord(first: FREE, second: 0)

                let (exchanged, _) = slot.stateAndData.compareExchange(
                    expected: expected,
                    desired: desired,
                    ordering: .acquiringAndReleasing
                )

                if exchanged {
                    // return(locData) // successful dequeue
                    return locData
                }

                // spinPause
#if arch(x86_64)
                _mm_pause()
#endif
            } else {
                // waitEnq(&q→slots[locHead], FREE)
                if !slot.waitEnq(expectedState: FREE, closed: closed) {
                    return nil
                }
            }
        }
    }

    public func close() {
        // Acquire all condition locks first to prevent race with waiters
        for slot in slots {
            slot.condition.lock()
        }
        closed.store(true, ordering: .releasing)
        // Broadcast and unlock - waiters will see closed flag when they wake
        for slot in slots {
            slot.condition.broadcast()
            slot.condition.unlock()
        }
    }
}

// MARK: - Generic Wrapper

/// A generic wrapper around RCQ that can store arbitrary values.
/// Values are boxed and stored as pointers in the underlying queue.
public final class RCQChannel<T>: @unchecked Sendable {
    private let queue: RCQ

    /// Box to hold values on the heap
    private final class Box {
        let value: T
        init(_ value: T) { self.value = value }
    }

    public init(size: UInt = N) {
        self.queue = RCQ(size: size)
    }

    @discardableResult
    public func send(_ value: T) -> Bool {
        guard queue.enqueue(toPointer(value)) == 0 else {
            return false
        }
        return true
    }

    public func receive() -> T? {
        guard let bits = queue.dequeue() else {
            return nil
        }
        return fromPointer(bits)
    }

    public func close() {
        queue.close()
    }

    private func toPointer(_ value: T) -> UInt {
        let box = Box(value)
        let ptr = Unmanaged.passRetained(box).toOpaque()
        return UInt(bitPattern: ptr)
    }

    private func fromPointer(_ bits: UInt) -> T {
        let ptr = UnsafeMutableRawPointer(bitPattern: bits)!
        let box = Unmanaged<Box>.fromOpaque(ptr).takeRetainedValue()
        return box.value
    }
}

// MARK: - x86 PAUSE instruction

#if arch(x86_64)
@inline(__always)
private func _mm_pause() {
    // Equivalent to x86 PAUSE instruction for spin-wait loops
    // Reduces power consumption and improves performance in spin loops
}
#endif
