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

import os

/// A bounded, thread-safe pool of recently-seen comparison operands.
///
/// Backed by a fixed-capacity ring so it tracks the operands of *recent*
/// executions (most relevant to the input being mutated now) without unbounded
/// growth. `record` is on the comparison hot path; sampling is on the mutation
/// path. The active dictionary for the mutators on a given task is published
/// through the `current` task-local, installed by the engine around its loop.
public final class ComparisonDictionary: Sendable {
    private struct Storage {
        var ring: [UInt64]
        var cursor: Int = 0
        var filled: Int = 0
    }

    private let capacity: Int
    private let storage: OSAllocatedUnfairLock<Storage>

    /// - Parameter capacity: how many recent operands to retain (ring size).
    public init(capacity: Int = 1024) {
        precondition(capacity > 0, "ComparisonDictionary capacity must be positive")
        self.capacity = capacity
        self.storage = OSAllocatedUnfairLock(
            initialState: Storage(ring: Array(repeating: 0, count: capacity))
        )
    }

    /// Record a comparison operand. Cheap and lock-guarded — called from the
    /// comparison observer for every instrumented comparison.
    public func record(_ value: UInt64) {
        storage.withLock { s in
            s.ring[s.cursor] = value
            s.cursor = (s.cursor + 1) % capacity
            if s.filled < capacity { s.filled += 1 }
        }
    }

    /// Whether nothing has been recorded yet.
    public var isEmpty: Bool {
        storage.withLock { $0.filled == 0 }
    }

    /// Sample a uniformly-random recorded operand, or `nil` if empty.
    public func randomValue(using rng: inout FastRNG) -> UInt64? {
        // Draw the entropy before taking the lock — the withLock closure is
        // Sendable and cannot capture the inout RNG. Reduce modulo `filled`
        // inside the lock so the bound matches the snapshot under the lock.
        let draw = rng.next()
        return storage.withLock { s in
            guard s.filled > 0 else { return nil }
            return s.ring[Int(draw % UInt64(s.filled))]
        }
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
