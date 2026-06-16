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

//  The learned operand pool behind input-to-state (I2S) mutation.
//
//  Edge coverage gives no gradient on a data condition like `x == 0xDEADBEEF`
//  or a de Bruijn `i < c`: a near-miss and a hit trace the same edges, so random
//  mutation must stumble onto the exact value. I2S short-circuits that — it
//  feeds the OPERANDS of each instrumented comparison (delivered by the
//  trace-cmp comparison observer) into this dictionary, and numeric mutators
//  sample from it, jumping straight to a value some comparison cared about. This
//  is the auto-dictionary / RedQueen idea (laf-intel, AFL++ cmplog) cast for
//  PropertyTestingKit's typed inputs: the framework's Int/UInt mutators consult
//  `ComparisonDictionary.current`, and a workload's bespoke mutator may too.
//

import Atomics

/// A bounded, thread-safe pool of recently-seen comparison operands.
///
/// Backed by a fixed-capacity ring so it tracks the operands of *recent*
/// executions (most relevant to the input being mutated now) without unbounded
/// growth. `record` is on the comparison hot path; sampling is on the mutation
/// path. The active dictionary for the mutators on a given task is published
/// through the `current` task-local, installed by the engine around its loop.
public final class ComparisonDictionary: @unchecked Sendable {
    private let capacity: Int
    // Fixed ring of recent operands, each slot an atomic UInt64. `cursor` is a
    // monotonic write counter; a writer fetch-adds it for a unique index and
    // stores into `slot = cursor % capacity`. LOCK-FREE: this was an
    // OSAllocatedUnfairLock taken per comparison (Finding 42 — the I2S record
    // path fires for every instrumented comparison). A sampler reads a random
    // already-written slot; a read racing a write sees one whole value or the
    // other (per-slot atomic, no tear), which is fine for a best-effort pool.
    //
    // `@unchecked Sendable` because the raw atomic-storage pointer is not
    // automatically `Sendable`.
    private let ring: UnsafeMutablePointer<AtomicRep<UInt64>>
    private let cursor = UnsafeAtomic<UInt64>.create(0)

    /// - Parameter capacity: how many recent operands to retain (ring size).
    public init(capacity: Int = 1024) {
        precondition(capacity > 0, "ComparisonDictionary capacity must be positive")
        self.capacity = capacity
        ring = .allocate(capacity: capacity)
        ring.initialize(repeating: AtomicRep<UInt64>(0), count: capacity)
    }

    deinit {
        ring.deinitialize(count: capacity); ring.deallocate()
        cursor.destroy()
    }

    /// Operands recorded so far, capped at `capacity` (the live ring size).
    private var filled: Int { Int(min(cursor.load(ordering: .relaxed), UInt64(capacity))) }

    /// Record a comparison operand. Lock-free; called from the comparison
    /// observer for every instrumented comparison.
    public func record(_ value: UInt64) {
        let c = cursor.loadThenWrappingIncrement(ordering: .relaxed)
        let slot = Int(c % UInt64(capacity))
        UnsafeAtomic<UInt64>(at: ring + slot).store(value, ordering: .relaxed)
    }

    /// Whether nothing has been recorded yet.
    public var isEmpty: Bool {
        cursor.load(ordering: .relaxed) == 0
    }

    /// Sample a uniformly-random recorded operand, or `nil` if empty. For
    /// `filled < capacity` only slots `0..<filled` have been written (the cursor
    /// fills them in order), so a draw in that range never reads an empty slot.
    public func randomValue(using rng: inout FastRNG) -> UInt64? {
        let n = filled
        guard n > 0 else { return nil }
        let idx = Int(rng.next() % UInt64(n))
        return UnsafeAtomic<UInt64>(at: ring + idx).load(ordering: .relaxed)
    }

    /// The dictionary the current task's mutators should sample from, or `nil`
    /// when I2S is not active. Installed by the engine around its mutation loop
    /// via `ComparisonDictionary.$current.withValue(_:)`; numeric mutators read
    /// it. A task-local so it follows the engine's task and never leaks across
    /// independent engines.
    @TaskLocal public static var current: ComparisonDictionary?

    /// Opt-in switch for input-to-state mutation, read by the engine. Bind it
    /// around a `fuzz` call — `ComparisonDictionary.$inputToStateEnabled
    /// .withValue(true) { try await fuzz(...) }` — to enable I2S for just that
    /// campaign's task tree (no process-global state, so parallel campaigns and
    /// tests never race). The engine also honours the `PTK_INPUT_TO_STATE`
    /// environment variable for launch-time opt-in (e.g. eval harnesses).
    @TaskLocal public static var inputToStateEnabled: Bool = false
}
