//
//  RCQB.swift
//  Copyright © 2026 DoorDash. All rights reserved.
//
import Atomics
import Foundation

private let MAXSPINS: Int = 1000

// MARK: - RCQB Slot (Listing 2)

/// A slot in the RCQB array - uses single-word CAS on state only.
/// This allows data to be of arbitrary size since we don't need atomic access to it.
public final class RCQBSlot<T>: @unchecked Sendable {
    // state: uint (32 bits), initially FREE
    let state: ManagedAtomic<UInt>

    // data: can be arbitrary size since access is protected by state transitions
    private var _data: T?

    // waiters: uint (32 bits), initially 0
    let waiters: ManagedAtomic<UInt32>

    // Condition for wait/wake (replaces futex)
    private let condition = NSCondition()

    public init() {
        self.state = ManagedAtomic(FREE)
        self._data = nil
        self.waiters = ManagedAtomic(0)
    }

    /// Non-atomic data access - only safe when slot is in ENQPND or DEQPND state
    var data: T? {
        get { _data }
        set { _data = newValue }
    }

    /// Wake all waiting dequeuers
    func wakeDeq() {
        if waiters.load(ordering: .relaxed) > 0 {
            condition.lock()
            condition.broadcast()
            condition.unlock()
        }
    }

    /// Wait for state to change from expectedState
    /// Returns true if state changed, false if closed
    func waitForStateChange(expectedState: UInt, closed: ManagedAtomic<Bool>) -> Bool {
        // Spin for MAXSPINS iterations first
        for _ in 0..<MAXSPINS {
            if closed.load(ordering: .acquiring) {
                return false
            }
            let current = state.load(ordering: .acquiring)
            if current != expectedState {
                return true
            }
#if arch(x86_64)
            _mm_pause()
#endif
        }

        // Fall back to blocking
        waiters.wrappingIncrement(ordering: .relaxed)

        condition.lock()
        while state.load(ordering: .acquiring) == expectedState
                && !closed.load(ordering: .acquiring) {
            condition.wait()
        }
        condition.unlock()

        waiters.wrappingDecrement(ordering: .relaxed)

        return !closed.load(ordering: .acquiring)
    }
}

// MARK: - RCQB (Listing 2)

/// Relaxed Concurrent Queue - RCQB variant using blocking per-slot locks.
/// This variant allows arbitrary-sized data since state and data are not
/// atomically updated together. Instead, ENQPND/DEQPND states provide
/// mutual exclusion for data access.
public final class RCQB<T>: @unchecked Sendable {
    private let slots: [RCQBSlot<T>]
    private let head: ManagedAtomic<UInt>
    private let tail: ManagedAtomic<UInt>
    public let size: UInt
    private var closed: ManagedAtomic<Bool>

    public init(size: UInt = N) {
        precondition(size > 0 && (size & (size - 1)) == 0, "Size must be a power of 2")
        self.size = size
        self.slots = (0..<size).map { _ in RCQBSlot<T>() }
        self.head = ManagedAtomic(0)
        self.tail = ManagedAtomic(0)
        self.closed = ManagedAtomic(false)
    }

    // MARK: - Enqueue (Listing 2, lines 17-35)

    /// Enqueue operation using ENQPND state for per-slot locking.
    /// Returns true on success, false if closed.
    @discardableResult
    public func enqueue(_ d: T) -> Bool {
        guard !closed.load(ordering: .acquiring) else {
            return false
        }

        // locTail := atomicInc(&q→tail) & (N-1)
        let locTail = tail.wrappingIncrementThenLoad(ordering: .acquiringAndReleasing) &- 1
        let slotIndex = Int(locTail & (size - 1))
        let slot = slots[slotIndex]

        while true {
            // locState := atomicLoad(&q→slots[locTail].state)
            let locState = slot.state.load(ordering: .acquiring)

            // if (locState = FREE)
            if locState == FREE {
                // if (CAS(&q→slots[locTail].state, &locState, ENQPND) = true)
                let (exchanged, _) = slot.state.compareExchange(
                    expected: FREE,
                    desired: ENQPND,
                    ordering: .acquiringAndReleasing
                )

                if exchanged {
                    // q→slots[locTail].data := d  (non-atomic write, protected by ENQPND)
                    slot.data = d

                    // atomicStore(&q→slots[locTail].state, OCCUPIED)
                    slot.state.store(OCCUPIED, ordering: .releasing)

                    // wakeDeq(&q→slots[locTail])
                    slot.wakeDeq()

                    return true
                }
            }

            // spinPause
#if arch(x86_64)
            _mm_pause()
#endif
        }
    }

    // MARK: - Dequeue (Listing 2, lines 36-56)

    /// Dequeue operation using DEQPND state for per-slot locking.
    /// Returns nil if the queue is closed.
    public func dequeue() -> T? {
        // locHead := atomicInc(&q→head) & (N-1)
        let locHead = head.wrappingIncrementThenLoad(ordering: .acquiringAndReleasing) &- 1
        let slotIndex = Int(locHead & (size - 1))
        let slot = slots[slotIndex]

        while true {
            // locState := atomicLoad(&q→slots[locHead].state)
            let locState = slot.state.load(ordering: .acquiring)

            // if (locState = OCCUPIED)
            if locState == OCCUPIED {
                // if (CAS(&q→slots[locHead].state, &locState, DEQPND) = true)
                let (exchanged, _) = slot.state.compareExchange(
                    expected: OCCUPIED,
                    desired: DEQPND,
                    ordering: .acquiringAndReleasing
                )

                if exchanged {
                    // locData := q→slots[locHead].data  (non-atomic read, protected by DEQPND)
                    let locData = slot.data

                    // Clear data to release reference
                    slot.data = nil

                    // atomicStore(&q→slots[locHead].state, FREE)
                    slot.state.store(FREE, ordering: .releasing)

                    return locData
                }

#if arch(x86_64)
                _mm_pause()
#endif
            } else {
                // Wait for enqueuer to complete (state becomes OCCUPIED)
                // We wait on FREE or ENQPND
                if !slot.waitForStateChange(expectedState: locState, closed: closed) {
                    return nil
                }
            }
        }
    }

    public func close() {
        closed.store(true, ordering: .releasing)
        // Wake all waiters so they can observe the closed flag
        for slot in slots {
            slot.wakeDeq()
        }
    }
}
