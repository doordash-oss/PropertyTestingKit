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

//  A lock-free mutable holder with SyncBox's ergonomics minus the lock.
//

/// A `@Sendable`-closure-capturable mutable holder that takes NO lock.
///
/// Use ONLY for state confined to a single serial context — e.g. a coverage
/// engine's `decide`/`features` half, which the fuzz loop calls one-at-a-time per
/// engine (each engine owns its own instance, and the observer callbacks never
/// touch this state). It exists because a `@Sendable` closure cannot capture a
/// bare mutable `var`; the previous answer was `SyncBox` (an `NSLock`), but that
/// is a test utility never meant for the fuzz path (Finding 42). For state
/// genuinely shared across threads (per-dispatch observer accumulation), use a
/// lock-free structure (HitCountAccumulator / AtomicFeatureSet / EdgeUnionBitmap)
/// instead — this box gives no cross-thread safety.
///
/// `@unchecked Sendable` because the contract (single serial writer) is enforced
/// by the caller, not the type.
final class UncheckedBox<T>: @unchecked Sendable {
    var value: T

    init(_ value: T) {
        self.value = value
    }

    /// Mutate the value in place. Mirrors `SyncBox.update` so call sites migrate
    /// by changing only the type name.
    @discardableResult
    func update<Result>(_ transform: (inout T) throws -> Result) rethrows -> Result {
        try transform(&value)
    }
}
